defmodule Query.DistributedStream.FailuresTest do
  # Counts live pipeline processes, so it must not run beside other pipelines.
  use ExUnit.Case, async: false
  import TestHelpers

  # Crashing workers are plain processes, which log their exceptions.
  @moduletag :capture_log

  import Query.DistributedStream

  # Two partitions on this node, by value.
  defp by_parity(value) when is_integer(value), do: {node(), rem(value, 2) + 1}
  defp by_parity(_value), do: {node(), 1}

  # Runs `fun` (which builds and enumerates a pipeline) as the consumer in a fresh
  # process and returns {:ok, result}, {:exit, reason} when it exits and the exit is
  # caught, or {:down, reason} when the consumer dies. The consumer traps exits when
  # `trap` is true, like Guardian's query process.
  defp consume(fun, opts \\ []) do
    trap = Keyword.get(opts, :trap, true)
    parent = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, trap)

        result =
          try do
            {:ok, fun.()}
          catch
            :exit, reason -> {:exit, reason}
          end

        send(parent, {tag, result})
      end)

    receive do
      {^tag, result} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> result
        end

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:down, reason}
    after
      30_000 -> flunk("pipeline did not finish")
    end
  end

  defp assert_no_pipeline_left do
    await_no_processes_running([Query.DistributedStream], except: [self()])
  end

  # A crash reaches the consumer either as the worker's own reason (through the
  # links) or, when a receiver noticed the dead sender first, as a sender_down edge
  # failure. Either way the pipeline failed.
  defp assert_crash(reason, message) do
    case reason do
      {%RuntimeError{message: ^message}, stack} when is_list(stack) -> :ok
      {:distributed_stream, {:sender_down, :noproc}} -> :ok
      other -> flunk("unexpected failure reason: #{inspect(other)}")
    end
  end

  # Waits until the calling process's mailbox holds a matching message, without
  # taking it.
  defp await_message(matches?, attempts \\ 5_000) do
    {:messages, messages} = Process.info(self(), :messages)

    cond do
      Enum.any?(messages, matches?) -> :ok
      attempts == 0 -> exit(:await_message_timeout)
      true -> Process.sleep(1) && await_message(matches?, attempts - 1)
    end
  end

  defp await_gate(gate) do
    if :atomics.get(gate, 1) == 1 do
      true
    else
      Process.sleep(1)
      await_gate(gate)
    end
  end

  # Values large enough that each fills a 1,000-byte chunk on its own.
  defp big(i), do: {i, String.duplicate("x", 1_000)}

  test "a multi-stage pipeline returns every row once" do
    assert {:ok, rows} =
             consume(fn ->
               1..5_000
               |> fan_out(&by_parity/1)
               |> map(&(&1 * 2))
               |> fan_out(fn value -> {node(), rem(div(value, 2), 3) + 1} end)
               |> map(&(&1 + 1))
               |> fan_in()
               |> Enum.sort()
             end)

    assert rows == Enum.map(1..5_000, &(&1 * 2 + 1))
    assert_no_pipeline_left()
  end

  test "an empty input, and a stage that passes nothing on, return no rows" do
    assert {:ok, []} =
             consume(fn -> [] |> fan_out(&by_parity/1) |> fan_in() |> Enum.to_list() end)

    # The second stage's router gets {:done} without ever starting a worker.
    assert {:ok, []} =
             consume(fn ->
               1..100
               |> fan_out(&by_parity/1)
               |> flat_map(fn _ -> [] end)
               |> fan_out(&by_parity/1)
               |> map(& &1)
               |> fan_in()
               |> Enum.to_list()
             end)

    assert_no_pipeline_left()
  end

  test "senders that route to disjoint partitions complete" do
    # Odd values only ever reach partition 1 of the second stage, even values only
    # partition 2, so each second-stage worker has exactly one sender.
    assert {:ok, rows} =
             consume(fn ->
               1..2_000
               |> fan_out(&by_parity/1)
               |> fan_out(&by_parity/1)
               |> map(& &1)
               |> fan_in()
               |> Enum.sort()
             end)

    assert rows == Enum.to_list(1..2_000)
  end

  test "a stage that raises on one partition fails the pipeline with that error" do
    assert {:exit, reason} =
             consume(fn ->
               1..1_000
               |> fan_out(&by_parity/1)
               |> map(fn
                 500 -> raise "boom"
                 value -> value
               end)
               |> fan_in()
               |> Enum.to_list()
             end)

    assert_crash(reason, "boom")

    assert_no_pipeline_left()
  end

  test "an upstream failure after downstream rows were emitted still fails" do
    parent = self()
    gate = :atomics.new(1, [])

    assert {:exit, reason} =
             consume(fn ->
               1..2_000
               |> fan_out(&by_parity/1)
               |> map(fn
                 # Partition 2 (odd values) fails only after partition 1's rows are
                 # downstream.
                 1_999 ->
                   await_gate(gate)
                   raise "late"

                 value ->
                   big(value)
               end)
               |> fan_out(fn _ -> {node(), 1} end)
               |> map(& &1)
               |> fan_in()
               |> Stream.each(fn _ ->
                 send(parent, :consumer_has_rows)
                 :atomics.put(gate, 1, 1)
               end)
               |> Enum.to_list()
             end)

    # The failing worker had sent rows before, so its receivers monitor it and see
    # the crash itself, never :noproc.
    assert {%RuntimeError{message: "late"}, stack} = reason
    assert is_list(stack)
    assert_received :consumer_has_rows
    assert_no_pipeline_left()
  end

  test "a stage slower than 5 seconds completes" do
    assert {:ok, rows} =
             consume(fn ->
               1..10
               |> fan_out(&by_parity/1)
               |> map(fn
                 3 -> Process.sleep(5_500) && 3
                 value -> value
               end)
               |> fan_out(&by_parity/1)
               |> map(& &1)
               |> fan_in()
               |> Enum.sort()
             end)

    assert rows == Enum.to_list(1..10)
  end

  test "a killed worker fails the pipeline" do
    parent = self()

    task =
      Task.async(fn ->
        consume(fn ->
          1..10
          |> fan_out(&by_parity/1)
          |> map(fn
            5 ->
              send(parent, {:worker, self()})
              Process.sleep(:infinity)

            value ->
              value
          end)
          |> fan_in()
          |> Enum.to_list()
        end)
      end)

    assert_receive {:worker, worker}, 5_000
    Process.exit(worker, :kill)
    assert Task.await(task) == {:exit, :killed}
    assert_no_pipeline_left()
  end

  test "a final router that dies fails the pipeline with its reason" do
    for {signal, reason} <- [{:kill, :killed}, {:boom, :boom}] do
      parent = self()

      task =
        Task.async(fn ->
          consume(fn ->
            1..10
            |> fan_out(&by_parity/1)
            |> map(fn
              5 ->
                send(parent, :blocked)
                Process.sleep(:infinity)

              value ->
                value
            end)
            |> fan_in()
            |> Enum.to_list()
          end)
        end)

      assert_receive :blocked, 5_000

      [final_router] =
        Enum.filter(Process.list(), fn pid ->
          Process.info(pid, :current_function) ==
            {:current_function, {Query.DistributedStream, :final_route, 3}}
        end)

      Process.exit(final_router, signal)
      assert Task.await(task) == {:exit, reason}
      assert_no_pipeline_left()
    end
  end

  test "a non-trapping consumer dies with the failure reason" do
    assert {:down, reason} =
             consume(
               fn ->
                 1..10
                 |> fan_out(&by_parity/1)
                 |> map(fn
                   7 -> raise "boom"
                   value -> value
                 end)
                 |> fan_in()
                 |> Enum.to_list()
               end,
               trap: false
             )

    assert_crash(reason, "boom")

    assert_no_pipeline_left()
  end

  test "a non-trapping consumer survives its own halt while every stage is busy" do
    # Stopping one pipeline process makes others fail (a worker sees its receiver
    # die). The consumer traps exits while it
    # signals them all and unlinks only afterwards, or it would die of its own halt.
    for _ <- 1..100 do
      assert {:ok, [_, _, _, _, _]} =
               consume(
                 fn ->
                   Stream.iterate(1, &(&1 + 1))
                   |> fan_out(&by_parity/1)
                   |> map(& &1)
                   |> fan_out(&by_parity/1)
                   |> map(& &1)
                   |> fan_out(&by_parity/1)
                   |> map(& &1)
                   |> fan_in()
                   |> Enum.take(5)
                 end,
                 trap: false
               )
    end

    assert_no_pipeline_left()
  end

  test "stopping early halts workers even while they are blocked in a call" do
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    :sys.suspend(agent)
    parent = self()

    for trap <- [true, false] do
      # The other partition's rows wait until this one is blocked, so the LIMIT can't
      # be met before it.
      gate = :atomics.new(1, [])

      assert {:ok, [_, _]} =
               consume(
                 fn ->
                   1..100_000
                   |> fan_out(&by_parity/1)
                   |> map(fn
                     # One partition blocks forever in an :infinity call.
                     2 ->
                       :atomics.put(gate, 1, 1)
                       send(parent, {:blocked, self()})
                       Agent.get(agent, & &1, :infinity)

                     value ->
                       await_gate(gate) && value
                   end)
                   |> fan_in()
                   |> Enum.take(2)
                 end,
                 trap: trap
               )

      assert_receive {:blocked, blocked}
      assert_no_pipeline_left()
      refute Process.alive?(blocked)
    end

    :sys.resume(agent)
  end

  test "killing the consumer mid-run leaves no pipeline process alive" do
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    :sys.suspend(agent)
    parent = self()

    consumer =
      spawn(fn ->
        1..1_000
        |> fan_out(&by_parity/1)
        |> map(fn
          2 ->
            send(parent, {:blocked, self()})
            Agent.get(agent, & &1, :infinity)

          value ->
            value
        end)
        |> fan_out(&by_parity/1)
        |> map(& &1)
        |> fan_in()
        |> Enum.to_list()
      end)

    assert_receive {:blocked, blocked}, 5_000
    Process.exit(consumer, :kill)
    assert_no_pipeline_left()
    refute Process.alive?(blocked)
    :sys.resume(agent)
  end

  test "a consumer that catches the failure, or stops early, can run the next pipeline" do
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    :sys.suspend(agent)
    parent = self()

    # The consumer stays alive throughout, so only its own cleanup can have stopped
    # the pipeline it abandoned.
    {consumer, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)

        failed =
          catch_exit(
            1..1_000
            |> fan_out(&by_parity/1)
            |> map(fn
              # Partition 1 fails while partition 2 is blocked.
              1 ->
                Process.sleep(100)
                raise "boom"

              2 ->
                Agent.get(agent, & &1, :infinity)

              value ->
                value
            end)
            |> fan_in()
            |> Enum.to_list()
          )

        send(parent, {:failed, failed})
        receive do: (:continue -> :ok)

        # Stop early while the last stage is still sending: its marker and the
        # router's {:done} can arrive after the halt.
        taken =
          1..5_000
          |> fan_out(&by_parity/1)
          |> map(&big/1)
          |> fan_out(fn _ -> {node(), 1} end)
          |> map(& &1)
          |> fan_in()
          |> Stream.each(fn _ -> Process.sleep(5) end)
          |> Enum.take(1)

        Process.sleep(100)

        full =
          1..2_000
          |> fan_out(&by_parity/1)
          |> fan_out(&by_parity/1)
          |> map(& &1)
          |> fan_in()
          |> Enum.sort()

        send(parent, {:next, taken, full, Process.info(self(), :links)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:failed, failed}, 5_000
    assert_crash(failed, "boom")
    assert_no_pipeline_left()
    {:links, []} = Process.info(consumer, :links)
    send(consumer, :continue)

    assert_receive {:next, [{1, _}], full, {:links, []}}, 10_000
    assert full == Enum.to_list(1..2_000)
    assert_no_pipeline_left()
    send(consumer, :stop)
    assert_receive {:DOWN, ^ref, :process, ^consumer, :normal}
    :sys.resume(agent)
  end

  test "nested pipelines: an inner failure fails the outer pipeline" do
    inner = fn fail_on ->
      1..1_000
      |> fan_out(&by_parity/1)
      |> map(fn
        ^fail_on -> raise "inner"
        value -> value
      end)
      |> fan_in()
    end

    # A plain stream wrapping the inner pipeline is the outer pipeline's input, so the
    # outer initial worker is the inner consumer (as in Guardian's ORDER BY ... LIMIT
    # after a {:default} step).
    assert {:exit, reason} =
             consume(fn ->
               inner.(600)
               |> Stream.map(& &1)
               |> fan_out(&by_parity/1)
               |> map(& &1)
               |> fan_in()
               |> Enum.to_list()
             end)

    assert_crash(reason, "inner")

    assert_no_pipeline_left()

    assert {:ok, rows} =
             consume(fn ->
               inner.(:never)
               |> Stream.map(& &1)
               |> fan_out(&by_parity/1)
               |> map(& &1)
               |> fan_in()
               |> Enum.sort()
             end)

    assert rows == Enum.to_list(1..1_000)
  end

  test "nested pipelines: halting the outer pipeline stops the inner one" do
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    :sys.suspend(agent)
    parent = self()

    gate = :atomics.new(1, [])

    inner =
      1..100_000
      |> fan_out(&by_parity/1)
      |> map(fn
        2 ->
          :atomics.put(gate, 1, 1)
          send(parent, {:blocked, self()})
          Agent.get(agent, & &1, :infinity)

        value ->
          await_gate(gate) && value
      end)
      |> fan_in()

    assert {:ok, [_]} =
             consume(fn ->
               inner
               |> Stream.map(& &1)
               |> fan_out(&by_parity/1)
               |> map(& &1)
               |> fan_in()
               |> Enum.take(1)
             end)

    assert_receive {:blocked, blocked}
    assert_no_pipeline_left()
    refute Process.alive?(blocked)
    :sys.resume(agent)
  end

  # A sender's stream that sends two chunks and then a marker claiming 99. The
  # sender waits for the first chunk's acknowledgement itself; the stream reads the
  # second chunk's (putting it back for the sender), and sends that receiver the marker.
  defp forged_marker_stream do
    Stream.resource(
      fn -> :start end,
      fn
        :start ->
          # Each big enough to fill a chunk, so both are sent before the stream goes on.
          {[String.duplicate("x", 1_000), String.duplicate("y", 1_000)], :wait}

        :wait ->
          receive do
            {:ready_for_input, id, receiver} = ack ->
              send(self(), ack)
              send(receiver, {:end_of_input, id, self(), 99})
              {:halt, :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  test "a marker whose chunk count doesn't match fails the pipeline" do
    # The input stream runs in the initial worker, the first stage's only sender, so a
    # worker gets the forged marker.
    assert {:exit, {:distributed_stream, {:lost_input, _}}} =
             consume(fn ->
               forged_marker_stream()
               |> fan_out(fn _ -> {node(), 1} end)
               |> map(& &1)
               |> fan_in()
               |> Enum.to_list()
             end)

    assert_no_pipeline_left()

    # The last stage's worker sends it to the consumer.
    assert {:exit, {:distributed_stream, {:lost_input, _}}} =
             consume(fn ->
               [1]
               |> fan_out(fn _ -> {node(), 1} end)
               |> transform(
                 &Stream.concat(Stream.reject(&1, fn _ -> true end), forged_marker_stream())
               )
               |> fan_in()
               |> Enum.to_list()
             end)

    assert_no_pipeline_left()
  end

  defp exit_after_one_chunk(stream, exit_fun) do
    Stream.concat(
      Stream.map(stream, &big/1),
      Stream.map([:stop], fn :stop ->
        # Let the chunk reach the receiver before exiting.
        Process.sleep(50)
        exit_fun.()
      end)
    )
  end

  defp run_exiting_stage(exit_fun) do
    consume(fn ->
      1..3
      |> fan_out(fn _ -> {node(), 1} end)
      |> transform(&exit_after_one_chunk(&1, exit_fun))
      |> fan_out(fn _ -> {node(), 1} end)
      |> map(& &1)
      |> fan_in()
      |> Enum.to_list()
    end)
  end

  test "a worker whose transform calls exit(:normal) fails the pipeline" do
    # Its router sees it exit without reporting that it finished, or its receiver sees
    # it go down without its marker.
    assert {:exit, {:distributed_stream, reason}} = run_exiting_stage(fn -> exit(:normal) end)
    assert reason == :worker_exited or match?({:sender_down, _}, reason)

    assert_no_pipeline_left()
  end

  test "a sender that dies normally without its marker fails the pipeline" do
    # An exit signal to itself can't be caught, so the worker really ends with reason
    # :normal and its marker never comes.
    assert {:exit, {:distributed_stream, reason}} =
             run_exiting_stage(fn -> Process.exit(self(), :normal) end)

    # Its router sees it exit without reporting that it finished, or its receiver sees
    # it go down without its marker.
    assert reason == :worker_exited or
             reason in [{:sender_down, :normal}, {:sender_down, :noproc}]

    assert_no_pipeline_left()
  end

  test "a receiver that stops reading early fails its senders" do
    assert {:exit, {:distributed_stream, reason}} =
             consume(fn ->
               1..100
               |> fan_out(fn _ -> {node(), 1} end)
               |> map(&big/1)
               |> fan_out(fn _ -> {node(), 1} end)
               |> transform(&Stream.take(&1, 1))
               |> fan_in()
               |> Enum.to_list()
             end)

    assert match?({:receiver_down, _}, reason) or reason == :worker_finished_early
    assert_no_pipeline_left()
  end

  test "a worker that reads part of a small input fails after its senders finished" do
    # The whole input is one chunk, acknowledged before the transform stops reading,
    # so no sender is left to notice. The transform waits until its router's {:done}
    # has arrived (so every sender has sent its marker) before returning, so the early
    # stop is all that's wrong.
    assert {:exit, {:distributed_stream, :worker_finished_early}} =
             consume(fn ->
               [1, 2, 3]
               |> fan_out(fn _ -> {node(), 1} end)
               |> transform(fn stream ->
                 [first] = Enum.take(stream, 1)
                 await_message(&match?({:done, _id, _senders}, &1))
                 [first]
               end)
               |> fan_in()
               |> Enum.to_list()
             end)

    assert_no_pipeline_left()
  end

  test "an input stream that exits normally fails instead of hanging" do
    assert {:exit, {:distributed_stream, :input_exited}} =
             consume(fn ->
               Stream.map([1, 2], fn
                 2 -> exit(:normal)
                 value -> value
               end)
               |> fan_out(fn _ -> {node(), 1} end)
               |> map(& &1)
               |> fan_in()
               |> Enum.to_list()
             end)
  end

  # An input that ends before its router could watch it once made the router exit
  # with a bare :noproc (about 8 runs in 1,000) instead of the input's own reason.
  test "an input that exits at once always fails with its own reason" do
    run = fn input_fun ->
      consume(fn ->
        Stream.map([1], input_fun)
        |> fan_out(fn _ -> {node(), 1} end)
        |> map(& &1)
        |> fan_in()
        |> Enum.to_list()
      end)
    end

    for _ <- 1..1_000 do
      assert run.(fn _ -> exit(:normal) end) == {:exit, {:distributed_stream, :input_exited}}
    end

    assert_no_pipeline_left()

    for _ <- 1..1_000 do
      assert run.(fn _ -> exit(:input_failed) end) == {:exit, :input_failed}
    end

    assert_no_pipeline_left()
  end

  test "successful runs leave the consumer's mailbox and links clean" do
    {:ok, {messages, links}} =
      consume(fn ->
        for _ <- 1..20 do
          [_ | _] = 1..1_000 |> fan_out(&by_parity/1) |> map(& &1) |> fan_in() |> Enum.to_list()
        end

        # Late EXITs from routers that were still exiting would arrive here.
        Process.sleep(50)
        {:messages, messages} = Process.info(self(), :messages)
        {:links, links} = Process.info(self(), :links)
        {messages, links}
      end)

    assert messages == []
    assert links == []
  end
end

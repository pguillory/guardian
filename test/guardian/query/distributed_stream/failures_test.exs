defmodule Guardian.Query.DistributedStream.FailuresTest do
  use ExUnit.Case, async: true

  import Guardian.Query.DistributedStream

  # Two partitions on this node, by value.
  defp by_parity(value) when is_integer(value) do
    {node(), rem(value, 2) + 1}
  end

  defp by_parity(_value) do
    {node(), 1}
  end

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

  # Waits for `pid`, a pipeline process the test holds, to stop.
  defp assert_stops(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
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
  defp big(i) do
    {i, String.duplicate("x", 1_000)}
  end

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
  end

  test "a final router that dies fails the pipeline with its reason" do
    for {signal, reason} <- [{:kill, :killed}, {:boom, :boom}] do
      parent = self()

      task =
        Task.async(fn ->
          consume(fn ->
            send(parent, {:consumer, self()})

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

      assert_receive {:consumer, consumer}, 5_000
      assert_receive :blocked, 5_000

      # The consumer links its pipeline's final router.
      {:links, links} = Process.info(consumer, :links)

      [final_router] =
        Enum.filter(links, fn pid ->
          Process.info(pid, :current_function) ==
            {:current_function, {Guardian.Query.DistributedStream, :final_route, 3}}
        end)

      Process.exit(final_router, signal)
      assert Task.await(task) == {:exit, reason}
    end
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
      assert_stops(blocked)
    end

    :sys.resume(agent)
  end

  # Spawns a consumer that runs `consume` over a two-stage pipeline in which the worker
  # given 2 blocks on the suspended `agent`, and returns the consumer, monitored, and
  # that worker once it is blocked. The odd values keep flowing in their own chunks,
  # so the consumer still receives rows meanwhile.
  defp spawn_blocked_consumer(agent, consume) do
    parent = self()

    {consumer, ref} =
      spawn_monitor(fn ->
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
        |> consume.()
      end)

    assert_receive {:blocked, blocked}, 5_000
    {consumer, ref, blocked}
  end

  test "killing the consumer mid-run stops its blocked worker" do
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    :sys.suspend(agent)
    {consumer, _ref, blocked} = spawn_blocked_consumer(agent, &Enum.to_list/1)
    Process.exit(consumer, :kill)
    assert_stops(blocked)
    :sys.resume(agent)
  end

  # Suspending enumeration and returning skips the stream's after-cleanup, so only the
  # routers' handling of the consumer's normal EXIT stops the pipeline. The consumer
  # returns only when told to, after the worker is known to be blocked.
  test "a consumer that exits normally mid-run stops its blocked worker" do
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    :sys.suspend(agent)

    {consumer, ref, blocked} =
      spawn_blocked_consumer(agent, fn stream ->
        {:suspended, _row, _continuation} =
          Enumerable.reduce(stream, {:cont, nil}, fn row, _acc -> {:suspend, row} end)

        receive do
          :return -> :ok
        end
      end)

    send(consumer, :return)
    assert_receive {:DOWN, ^ref, :process, ^consumer, :normal}, 5_000
    assert_stops(blocked)
    :sys.resume(agent)
  end

  test "a consumer that stops early can run the next pipeline" do
    parent = self()

    {consumer, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)

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

    assert_receive {:next, [{1, _}], full, {:links, []}}, 10_000
    assert full == Enum.to_list(1..2_000)
    send(consumer, :stop)
    assert_receive {:DOWN, ^ref, :process, ^consumer, :normal}
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
    assert_stops(blocked)
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

    for _ <- 1..1_000 do
      assert run.(fn _ -> exit(:input_failed) end) == {:exit, :input_failed}
    end
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

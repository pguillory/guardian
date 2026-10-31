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

  test "a consumer that stops early can run the next pipeline" do
    assert {:ok, {[{_, _}], full}} =
             consume(fn ->
               # Stop early while the last stage is still sending: its marker and the
               # router's {:done} can arrive after the halt.
               taken =
                 1..5_000
                 |> fan_out(&by_parity/1)
                 |> map(&big/1)
                 |> fan_out(fn _ -> {node(), 1} end)
                 |> map(& &1)
                 |> fan_in()
                 |> Enum.take(1)

               full =
                 1..2_000
                 |> fan_out(&by_parity/1)
                 |> fan_out(&by_parity/1)
                 |> map(& &1)
                 |> fan_in()
                 |> Enum.sort()

               {taken, full}
             end)

    assert full == Enum.to_list(1..2_000)
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
end

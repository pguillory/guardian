defmodule Guardian.Query.HeapLimitTest do
  # The test environment's heap limit (16 MiB, config/config.exs) is what these exceed.
  use ExUnit.Case, async: true
  import Guardian.Query.Limits, only: [max_heap_mb: 0]
  import Guardian.Test.Query
  import Guardian.Test.Tables, only: [unique_table: 1]

  alias Guardian.Query.DistributedStream

  # Runs a pipeline as a trapping consumer, like the query process, in a fresh process.
  defp consume(fun) do
    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        try do
          {:ok, fun.()}
        catch
          :exit, reason -> {:exit, reason}
        end
      end)

    Task.await(task, 30_000)
  end

  test "limit_heap/0 puts this node's limit on the process" do
    info =
      Task.async(fn ->
        Guardian.Query.Limits.limit_heap()
        Process.info(self(), :max_heap_size)
      end)
      |> Task.await()

    words = div(max_heap_mb() * 1024 * 1024, :erlang.system_info(:wordsize))

    assert {:max_heap_size,
            %{size: ^words, kill: true, error_logger: false, include_shared_binaries: false}} =
             info
  end

  test "a worker over the limit fails the pipeline" do
    result =
      consume(fn ->
        [1, 2]
        |> DistributedStream.fan_out(fn value -> {node(), value} end)
        |> DistributedStream.map(&Guardian.Test.DistributedStreamStages.grow_heap/1)
        |> DistributedStream.fan_in()
        |> Enum.to_list()
      end)

    assert result == {:exit, :killed}
  end

  test "the initial worker, which reads the input, is limited too" do
    result =
      consume(fn ->
        Stream.map([1], &Guardian.Test.DistributedStreamStages.grow_heap/1)
        |> DistributedStream.fan_out(fn _ -> {node(), 1} end)
        |> DistributedStream.fan_in()
        |> Enum.to_list()
      end)

    assert result == {:exit, :killed}
  end

  test "a query over the limit fails with the heap message" do
    table = unique_table("heap_limit")
    Guardian.Engine.ingest_events(table, Enum.map(1..20_000, &%{"v" => &1}))

    # 100 integers a row over 20,000 rows: a worker's segment of them, or the result in
    # the query process, is over the limit. Either kill gives the same message.
    columns = Enum.map_join(1..100, ", ", &"v AS c#{&1}")
    error = catch_error(run_sql("SELECT #{columns} FROM #{table}"))
    assert %Guardian.Query.Error{message: message} = error
    assert message == Guardian.Query.Limits.heap_kill_message()
    assert run_sql("SELECT count() FROM #{table}") == [[20_000]]
  end

  test "the heap message names the limit" do
    assert Guardian.Query.Limits.heap_kill_message() ==
             "a query process was killed; it may have exceeded its #{max_heap_mb()} MiB heap " <>
               "limit; narrow the query with WHERE, LIMIT or fewer groups"
  end

  test "a killed process is reported with the heap message, from the pipeline or the query" do
    assert Guardian.Query.Failure.from_exit(:killed).message ==
             Guardian.Query.Limits.heap_kill_message()

    assert Guardian.Query.Failure.query_process_down(:killed).message ==
             Guardian.Query.Limits.heap_kill_message()
  end
end

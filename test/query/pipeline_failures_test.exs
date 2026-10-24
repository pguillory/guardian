defmodule Query.PipelineFailuresTest do
  # A query either returns every row or fails with an error; its workers never
  # outlive it. Counts live processes and suspends segments, so it runs alone.
  use ExUnit.Case, async: false
  import TestHelpers

  defp table, do: "pipeline_failures_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"

  # Three full segments plus a partial one.
  defp fill(table, rows \\ 3 * 16_384 + 100) do
    1..rows
    |> Enum.map(&%{"g" => rem(&1, 7), "v" => &1})
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Engine.ingest_events(table, &1))

    rows
  end

  # A full segment, loaded; see TestHelpers.loaded_segment/2.
  defp segment(table, index \\ 1), do: loaded_segment(table, index)

  defp assert_no_query_processes_left do
    await_no_processes_running([Query.DistributedStream, Query, Query.Executor], except: [self()])
  end

  # Query workers blocked reading a segment (only one query runs at a time here).
  defp blocked_readers, do: processes_running_all([Query.Executor, Storage.Segment])

  # Polls until `fun` returns a nonempty list, and returns it.
  defp await_nonempty(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    case fun.() do
      [] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met")
        else
          Process.sleep(10)
          await_nonempty(fun, deadline)
        end

      result ->
        result
    end
  end

  test "a killed worker fails the query instead of dropping its rows" do
    table = table()
    fill(table)
    {_id, segment} = segment(table)
    :sys.suspend(segment)

    task = Task.async(fn -> catch_error(run_sql("SELECT count() FROM #{table}")) end)
    [worker | _] = await_nonempty(&blocked_readers/0)
    Process.exit(worker, :kill)
    :sys.resume(segment)

    assert %Query.Error{message: message} = Task.await(task)
    assert message == Query.Limits.heap_kill_message()
    assert_no_query_processes_left()
  end

  test "killing the caller mid-query stops every query process" do
    table = table()
    fill(table)
    {_id, segment} = segment(table)
    :sys.suspend(segment)

    caller = spawn(fn -> run_sql("SELECT g, count() FROM #{table} GROUP BY g") end)
    await_nonempty(&blocked_readers/0)
    Process.exit(caller, :kill)

    assert_no_query_processes_left()
    :sys.resume(segment)
  end

  test "a LIMIT returns while workers are still running, and stops them" do
    table = table()
    rows = fill(table)
    {_id, segment} = segment(table, 2)
    :sys.suspend(segment)

    # The FROM worker blocks on the suspended segment after producing earlier rows.
    assert [_, _, _] = run_sql("SELECT v FROM #{table} LIMIT 3")
    assert_no_query_processes_left()
    :sys.resume(segment)

    assert run_sql("SELECT count() FROM #{table}") == [[rows]]
  end

  test "repeated queries leave the caller's mailbox, links and monitors clean" do
    table = table()
    fill(table, 1_000)

    queries = [
      "SELECT count() FROM #{table}",
      "SELECT g, count() FROM #{table} GROUP BY g",
      "SELECT v FROM #{table} ORDER BY v DESC LIMIT 3",
      "SELECT count() FROM #{table} ORDER BY 1 LIMIT 5",
      "SELECT v FROM #{table} LIMIT 2",
    ]

    for _ <- 1..10, query <- queries, do: run_sql(query)

    assert_raise Query.Error, ~r/test_raise/, fn ->
      run_sql("SELECT test_raise(v) FROM #{table}")
    end

    assert Process.info(self(), :messages) == {:messages, []}
    assert Process.info(self(), :links) == {:links, []}
    assert Process.info(self(), :monitors) == {:monitors, []}
    assert_no_query_processes_left()
  end

  test "counts during ingest never lose or duplicate rows" do
    table = table()
    writer_rows = 40_000

    writer =
      Task.async(fn ->
        1..writer_rows
        |> Enum.chunk_every(500)
        |> Enum.each(fn chunk ->
          Engine.ingest_events(table, Enum.map(chunk, &%{"v" => &1}))
        end)
      end)

    counts =
      Stream.repeatedly(fn ->
        [[count, sum]] = run_sql("SELECT count(), sum(v) FROM #{table}")
        {count, sum}
      end)
      |> Enum.take(30)

    Task.await(writer, 60_000)

    # Rows arrive in order, so a snapshot of n rows holds exactly 1..n.
    for {count, sum} <- counts do
      assert count <= writer_rows
      assert sum == div(count * (count + 1), 2)
    end

    assert counts == Enum.sort(counts)
    assert run_sql("SELECT count(), sum(v) FROM #{table}") |> hd() |> hd() == writer_rows
  end
end

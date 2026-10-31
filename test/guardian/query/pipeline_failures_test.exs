defmodule Guardian.Query.PipelineFailuresTest do
  # A query either returns every row or fails with an error, and leaves its caller clean.
  use ExUnit.Case, async: true
  import Guardian.Test.Query

  defp table do
    "pipeline_failures_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  end

  defp fill(table, rows) do
    1..rows
    |> Enum.map(&%{"g" => rem(&1, 7), "v" => &1})
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Guardian.Engine.ingest_events(table, &1))
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

    assert_raise Guardian.Query.Error, ~r/test_raise/, fn ->
      run_sql("SELECT test_raise(v) FROM #{table}")
    end

    assert Process.info(self(), :messages) == {:messages, []}
    assert Process.info(self(), :links) == {:links, []}
    assert Process.info(self(), :monitors) == {:monitors, []}
  end

  test "counts during ingest never lose or duplicate rows" do
    table = table()
    writer_rows = 40_000

    writer =
      Task.async(fn ->
        1..writer_rows
        |> Enum.chunk_every(500)
        |> Enum.each(fn chunk ->
          Guardian.Engine.ingest_events(table, Enum.map(chunk, &%{"v" => &1}))
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
      # The sum of no rows is null.
      assert sum == if(count == 0, do: nil, else: div(count * (count + 1), 2))
    end

    assert counts == Enum.sort(counts)
    assert run_sql("SELECT count(), sum(v) FROM #{table}") |> hd() |> hd() == writer_rows
  end
end

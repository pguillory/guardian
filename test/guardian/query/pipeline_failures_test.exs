defmodule Guardian.Query.PipelineFailuresTest do
  # Counts stay exact while rows arrive.
  use ExUnit.Case, async: true
  import Guardian.Test.Query

  defp table do
    "pipeline_failures_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
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

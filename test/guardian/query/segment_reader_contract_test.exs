defmodule Guardian.Query.SegmentReaderContractTest do
  # A segment that disappears during a query fails it, naming the segment.
  use ExUnit.Case, async: true

  defp table do
    "reader_contract_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  end

  defp fill(table, rows) do
    1..rows
    |> Enum.map(&%{"v" => &1})
    |> Enum.chunk_every(5_000)
    |> Enum.each(&Guardian.Engine.ingest_events(table, &1))
  end

  test "a segment that is gone before its columns are read fails the query, naming it" do
    table = table()
    fill(table, 100)
    [id] = table |> Guardian.Storage.segment_ids() |> Enum.to_list()
    :ok = Guardian.Storage.delete_segment(id)

    snapshot = %Guardian.Query.Evaluation.SegmentSnapshot{segment: id, count: 100}

    assert_raise Guardian.Query.Error,
                 "segment #{id} became unavailable during the query (it was deleted, expired, or moved to its file)",
                 fn ->
                   Guardian.Query.Evaluation.eval(snapshot, %Guardian.AST.Node.Identifier{
                     name: "v",
                   })
                 end
  end

  test "the message names the configured limit" do
    assert Guardian.Query.Limits.time_limit_message(30_000) =~ "time limit of 30 seconds"
    assert Guardian.Query.Limits.time_limit_message(1_000) =~ "time limit of 1 second"
    assert Guardian.Query.Limits.time_limit_message(1_500) =~ "time limit of 1500 ms"
  end
end

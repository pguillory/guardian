defmodule Guardian.Storage.MutableSegmentsTest do
  import Guardian.Storage.MutableSegments
  use ExUnit.Case, async: true

  test "append" do
    :ok = append("MutableSegmentsTest", a: 1)
  end

  test "a row that fills a segment hands it off at once" do
    table = "mutable_segments_budget_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ok = Guardian.Storage.delete_table(table) end)

    # One row over the default 64 MiB byte budget.
    string = String.duplicate("s", 61_000)
    row = Map.new(1..1100, fn i -> {"k#{i}", string} end)

    :ok = append(table, a: 1)
    [segment] = get_mutable_segments(table)
    :ok = append(table, row)

    # Handed off without waiting for another row to arrive.
    assert get_mutable_segments(table) == []
    assert Guardian.Storage.table_row_count(table) == 2
    assert {:ok, 2} = Guardian.Storage.Segment.count(segment)

    # Load the persisted file, so that deleting the table removes it.
    :sys.get_state(Guardian.Storage.PersistedSegments)
    :ok = Guardian.Test.Segments.load_persisted(table)
  end
end

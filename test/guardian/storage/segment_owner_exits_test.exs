defmodule Guardian.Storage.SegmentOwnerExitsTest do
  # How the lifecycle managers handle their segments' ends.
  use ExUnit.Case, async: true
  import Guardian.Test.Query
  import Guardian.Test.Polling

  alias Guardian.Storage.FullSegments
  alias Guardian.Storage.MutableSegments
  alias Guardian.Storage.PersistedSegments
  alias Guardian.Storage.Segment

  defp table do
    "owner_exits_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  end

  # Every stored value of `v` in the table, sorted, so a lost or duplicated row shows.
  defp values(table) do
    run_sql("select v from #{table}") |> Enum.map(&hd/1) |> Enum.sort()
  end

  defp segment(rows) do
    {:ok, segment} = Segment.start_link()
    for v <- rows, do: :ok = Segment.append(segment, %{"v" => v})
    Process.unlink(segment)
    segment
  end

  defp full_fixture(table, rows) do
    segment = segment(rows)
    id = Guardian.SegmentID.generate()
    :ok = FullSegments.insert({id, segment, table})
    {id, segment}
  end

  defp persisted_fixture(table, rows) do
    {id, segment} = full_fixture(table, rows)
    on_exit(fn -> File.rm(Guardian.Storage.SegmentFile.filename(table, id)) end)
    :ok = PersistedSegments.ping()
    eventually(fn -> PersistedSegments.get_segment(id) == {:ok, segment} end)
    {id, segment}
  end

  test "normal exits are told apart from crashes" do
    assert Segment.normal_exit?(:normal)
    assert Segment.normal_exit?(:shutdown)
    assert Segment.normal_exit?({:shutdown, :x})
    refute Segment.normal_exit?(:boom)
  end

  test "deleting a table stops its mutable and persisted segments" do
    table = table()
    :ok = MutableSegments.ensure_at_least_n_mutable_segments(table, 3)
    for v <- 1..30, do: :ok = Guardian.Storage.append(table, %{"v" => v})
    mutable = MutableSegments.get_mutable_segments(table)
    assert length(mutable) == 3
    {_id, persisted} = persisted_fixture(table, 31..40)
    # Loaded must know the file, or deletion leaves it for the next restart to load
    # (deletion racing persistence is a separate, known gap).
    Guardian.Test.Segments.await_persisted(table)
    assert values(table) == Enum.to_list(1..40)

    segments = [persisted | mutable]
    refs = Map.new(segments, &{Process.monitor(&1), &1})

    :ok = Guardian.Storage.delete_table(table)

    for _ <- segments do
      assert_receive {:DOWN, ref, :process, _, _} when is_map_key(refs, ref)
    end

    assert Enum.to_list(Guardian.Storage.segment_ids(table)) == []
    assert values(table) == []
  end
end

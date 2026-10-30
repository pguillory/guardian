defmodule Guardian.Storage.SegmentOwnerExitsTest do
  # How the lifecycle managers handle their segments' ends: a handoff of a segment
  # that is already gone, table deletion, a segment that does not answer, and a late
  # reply to the persister.
  use ExUnit.Case, async: false
  import Guardian.Test.Query
  import Guardian.Test.Polling

  alias Guardian.Storage.FullSegments
  alias Guardian.Storage.LoadedSegments
  alias Guardian.Storage.MutableSegments
  alias Guardian.Storage.PersistedSegments
  alias Guardian.Storage.Schema
  alias Guardian.Storage.Segment

  @managers [Schema, LoadedSegments, FullSegments, PersistedSegments, MutableSegments]

  defp table do
    "owner_exits_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  end

  # A table whose segment filenames exceed the filesystem's 255-byte name limit, so its
  # full segments stay in FullSegments (the persister logs them and retries).
  defp unstorable_table do
    table() <> String.duplicate("f", 230)
  end

  # Every stored value of `v` in the table, sorted, so a lost or duplicated row shows.
  defp values(table) do
    run_sql("select v from #{table}") |> Enum.map(&hd/1) |> Enum.sort()
  end

  defp managers do
    Map.new([Guardian.Storage | @managers], &{&1, Process.whereis(&1)})
  end

  # Lets each manager handle every message already in its mailbox.
  defp sync do
    Enum.each(@managers, &:sys.get_state/1)
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

  test "a handoff of a segment that already died leaves no registration" do
    dead = spawn(fn -> :ok end)
    eventually(fn -> not Process.alive?(dead) end)
    before = managers()
    id = Guardian.SegmentID.generate()

    assert :ok = FullSegments.insert({id, dead, table()})
    eventually(fn -> FullSegments.get_segment(id) == {:error, :not_found} end)
    sync()
    assert managers() == before
  end

  test "normal exits are told apart from crashes" do
    assert Segment.normal_exit?(:normal)
    assert Segment.normal_exit?(:shutdown)
    assert Segment.normal_exit?({:shutdown, :x})
    refute Segment.normal_exit?(:boom)
  end

  test "deleting a table stops its mutable, full and persisted segments" do
    table = table()
    :ok = MutableSegments.ensure_at_least_n_mutable_segments(table, 3)
    for v <- 1..30, do: :ok = Guardian.Storage.append(table, %{"v" => v})
    mutable = MutableSegments.get_mutable_segments(table)
    assert length(mutable) == 3
    {_id, persisted} = persisted_fixture(table, 31..40)
    # Loaded must know the file, or deletion leaves it to be loaded again by a scan
    # (deletion racing persistence is a separate, known gap).
    :ok = LoadedSegments.rescan()
    assert values(table) == Enum.to_list(1..40)

    full_table = unstorable_table()
    {_id, full} = full_fixture(full_table, 1..10)

    segments = [persisted, full | mutable]
    refs = Map.new(segments, &{Process.monitor(&1), &1})

    :ok = Guardian.Storage.delete_table(table)
    :ok = Guardian.Storage.delete_table(full_table)

    for _ <- segments do
      assert_receive {:DOWN, ref, :process, _, _} when is_map_key(refs, ref)
    end

    assert Enum.to_list(Guardian.Storage.segment_ids(table)) == []
    assert Enum.to_list(Guardian.Storage.segment_ids(full_table)) == []
    assert values(table) == []
  end

  describe "Guardian.Storage.schema/1 and a mutable segment" do
    test "fails the lookup, by kind only, on one that does not answer" do
      table = table()
      :ok = Guardian.Storage.append(table, %{"v" => 1})
      [{_id, segment, ^table}] = :ets.match_object(MutableSegments, {:_, :_, table})
      :ok = :sys.suspend(segment)

      try do
        assert catch_exit(Guardian.Storage.schema(table)) == {:segment_unavailable, ":timeout"}
      after
        :ok = :sys.resume(segment)
      end

      assert Map.keys(Guardian.Storage.schema(table)) == ["v"]
      :ok = Guardian.Storage.delete_table(table)
    end
  end

  describe "the persister" do
    test "survives a segment that answers after its call timed out, and persists it later" do
      before = managers()
      table = table()
      persister = Process.whereis(PersistedSegments)
      slow = segment(1..3)
      :ok = :sys.suspend(slow)
      slow_id = Guardian.SegmentID.generate()
      on_exit(fn -> File.rm(Guardian.Storage.SegmentFile.filename(table, slow_id)) end)
      :ok = FullSegments.insert({slow_id, slow, table})
      :ok = PersistedSegments.ping()

      # A second queued freeze means the first call timed out and a later pass tried
      # again. Resumed, the segment answers both calls late, and the persister must
      # survive the stale reply and store the segment.
      eventually(
        fn ->
          {:messages, messages} = Process.info(slow, :messages)
          Enum.count(messages, &match?({:"$gen_call", {^persister, _}, :freeze}, &1)) >= 2
        end,
        15_000
      )

      :ok = :sys.resume(slow)
      eventually(fn -> PersistedSegments.get_segment(slow_id) == {:ok, slow} end, 15_000)
      sync()
      assert managers() == before
      assert values(table) == [1, 2, 3]
      :ok = Guardian.Storage.delete_table(table)
    end
  end
end

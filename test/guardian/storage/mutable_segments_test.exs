defmodule Guardian.Storage.MutableSegmentsTest do
  import Guardian.Storage.MutableSegments
  alias Guardian.Storage.Segment.Registration
  require Registration
  use ExUnit.Case, async: false
  import Guardian.Test.Polling

  test "append" do
    :ok = append("MutableSegmentsTest", a: 1)
  end

  test "a dead segment is unregistered and appends go elsewhere" do
    table = "mutable_segments_dead_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ok = Guardian.Storage.delete_table(table) end)

    :ok = append(table, a: 1)
    [segment] = get_mutable_segments(table)

    # Kill it and append at once, so the append may race the exit notification.
    Process.exit(segment, :kill)
    :ok = append(table, a: 2)

    :sys.get_state(Guardian.Storage.MutableSegments)
    refute segment in get_mutable_segments(table)
    assert Guardian.Storage.dump_table(table) == [%{"a" => 2}]
  end

  test "an append that picks a dead segment retries elsewhere" do
    table = "mutable_segments_stale_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ok = Guardian.Storage.delete_table(table) end)

    # A registration whose process died without this server noticing, as if the
    # append read the registry just before the exit was processed.
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    registration =
      Registration.tuple(segment_id: Guardian.SegmentID.generate(), segment: dead, table: table)

    :sys.replace_state(Guardian.Storage.MutableSegments, fn state ->
      true = :ets.insert(Guardian.Storage.MutableSegments, registration)
      state
    end)

    :ok = append(table, a: 1)
    refute dead in get_mutable_segments(table)
    assert Guardian.Storage.dump_table(table) == [%{"a" => 1}]
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
    :ok = Guardian.Storage.LoadedSegments.rescan()
  end

  describe "maximum age" do
    setup do
      original = :sys.get_state(Guardian.Storage.MutableSegments)
      :sys.replace_state(Guardian.Storage.MutableSegments, &%{&1 | max_age_ms: 50})

      table = "mutable_segments_age_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :sys.resume(Guardian.Storage.PersistedSegments)
        :sys.replace_state(Guardian.Storage.MutableSegments, fn _ -> original end)
        :sys.get_state(Guardian.Storage.PersistedSegments)
        :ok = Guardian.Storage.LoadedSegments.rescan()
        :ok = Guardian.Storage.delete_table(table)
      end)

      %{table: table}
    end

    test "quiet partial segments hand off, persist, and send later writes elsewhere", %{
      table: table,
    } do
      :sys.suspend(Guardian.Storage.PersistedSegments)
      :ok = append(table, a: 1)
      [id] = segment_ids(table)
      [segment] = get_mutable_segments(table)

      eventually(fn -> get_mutable_segments(table) == [] end)
      assert Guardian.Storage.FullSegments.segment_ids(table) == [id]
      assert Guardian.Storage.Segment.full(segment) == {:ok, true}
      assert Guardian.Storage.Segment.append(segment, %{a: 99}) == {:error, :full}

      # An append that had already picked this segment and a stale age message
      # can both ask for the same handoff; neither registers it twice.
      :ok = segment_is_full(table, segment)
      send(Guardian.Storage.MutableSegments, {:segment_max_age, segment})
      :sys.get_state(Guardian.Storage.MutableSegments)
      assert Guardian.Storage.FullSegments.segment_ids(table) == [id]

      # Keep the replacement writable while this test checks persistence.
      :sys.replace_state(Guardian.Storage.MutableSegments, &%{&1 | max_age_ms: 3_600_000})
      :ok = append(table, a: 2)
      [next_id] = segment_ids(table)
      refute next_id == id
      {:ok, next_segment} = get_segment(next_id)
      assert Guardian.Storage.Segment.get_row(next_segment, 0) == {:ok, %{"a" => 2}}
      assert Guardian.Storage.Segment.count(segment) == {:ok, 1}

      :sys.resume(Guardian.Storage.PersistedSegments)
      :sys.get_state(Guardian.Storage.PersistedSegments)
      filename = Guardian.Storage.SegmentFile.filename(table, id)
      assert File.exists?(filename)
      assert {:ok, ^segment} = Guardian.Storage.PersistedSegments.get_segment(id)

      # Read the actual persisted bytes through the normal mmap loader.
      :ok = Guardian.Storage.LoadedSegments.rescan()
      {:ok, loaded} = Guardian.Storage.LoadedSegments.get_segment(id)
      assert Guardian.Storage.Segment.get_row(loaded, 0) == {:ok, %{"a" => 1}}
      assert Guardian.Storage.dump_table(table) == [%{"a" => 1}, %{"a" => 2}]
    end

    test "empty segments stay mutable until their first write", %{table: table} do
      :ok = ensure_at_least_n_mutable_segments(table, 1)
      [id] = segment_ids(table)
      [segment] = get_mutable_segments(table)
      Process.sleep(100)

      assert segment_ids(table) == [id]
      assert Guardian.Storage.Segment.full(segment) == {:ok, false}
      assert Guardian.Storage.Segment.count(segment) == {:ok, 0}
      assert Guardian.Storage.FullSegments.segment_ids(table) == []
      refute File.exists?(Guardian.Storage.SegmentFile.filename(table, id))

      :ok = append(table, a: 1)
      eventually(fn -> get_mutable_segments(table) == [] end)
      # The registry removal precedes the persistence ping inside the handoff.
      :sys.get_state(Guardian.Storage.MutableSegments)
      :sys.get_state(Guardian.Storage.PersistedSegments)
      assert File.exists?(Guardian.Storage.SegmentFile.filename(table, id))
    end
  end
end

defmodule Guardian.Storage.UnreadableSegmentsTest do
  # Not async: capture_log sees every process's log events, and the skipped-file
  # state and the segment directory are shared with every other test's rescans.
  use ExUnit.Case, async: false
  import Guardian.Test.Segments

  import ExUnit.CaptureLog

  alias Guardian.Storage.BlobStore
  alias Guardian.Storage.LoadedSegments
  alias Guardian.Storage.Segment

  @marker "PRIVATE_SEGMENT_MARKER_8273"

  setup do
    table = "unreadable_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      for filename <- Path.wildcard(Path.join(Guardian.Storage.segment_dir(), "#{table}.*.seg")) do
        BlobStore.delete(filename)
      end

      LoadedSegments.rescan()
    end)

    {:ok, table: table}
  end

  defp store_segment(table, segment_id, rows) do
    write_segment_file(Guardian.Storage.SegmentFile.filename(table, segment_id), rows)
  end

  # A segment file with its last byte cut off. The marker stays in the file, so a
  # log line that included the file's bytes would show it.
  defp truncated_segment(table, segment_id) do
    filename = store_segment(table, segment_id, [%{"secret" => @marker}, %{"secret" => "x"}])
    data = File.read!(filename)
    File.write!(filename, binary_part(data, 0, byte_size(data) - 1))
    assert File.read!(filename) =~ @marker
    filename
  end

  defp empty_segment(table, segment_id) do
    filename = Guardian.Storage.SegmentFile.filename(table, segment_id)
    File.mkdir_p!(Path.dirname(filename))
    File.write!(filename, "")
    filename
  end

  test "Segment.load/1 reports an unreadable file without its bytes", %{table: table} do
    truncated = truncated_segment(table, Guardian.SegmentID.generate())
    empty = empty_segment(table, Guardian.SegmentID.generate())

    log =
      capture_log(fn ->
        assert {:error, {:unreadable_segment, ArgumentError}} = Segment.load(truncated)
        assert {:error, {:unreadable_segment, ArgumentError}} = Segment.load(empty)

        missing = Guardian.Storage.SegmentFile.filename(table, Guardian.SegmentID.generate())
        assert {:error, {:unreadable_segment, {:mmap, :enoent}}} = Segment.load(missing)
      end)

    refute log =~ @marker
  end

  test "deleting a loaded segment whose file is gone or cannot be removed unloads it",
       %{table: table} do
    loaded_segments = Process.whereis(LoadedSegments)
    missing_id = Guardian.SegmentID.generate()
    stuck_id = Guardian.SegmentID.generate()
    missing = store_segment(table, missing_id, [%{"a" => 1}])
    stuck = store_segment(table, stuck_id, [%{"a" => 2}])
    :ok = LoadedSegments.rescan()

    # A directory where the file was: it exists, but removing it as a file fails.
    on_exit(fn -> File.rm_rf(stuck) end)
    File.rm!(missing)
    File.rm!(stuck)
    File.mkdir!(stuck)

    log =
      capture_log(fn ->
        :ok = LoadedSegments.delete_segment(missing_id)
        :ok = LoadedSegments.delete_segment(stuck_id)
      end)

    assert Process.whereis(LoadedSegments) == loaded_segments
    assert LoadedSegments.get_segment(missing_id) == {:error, :not_found}
    assert LoadedSegments.get_segment(stuck_id) == {:error, :not_found}
    assert log =~ "Missing segment #{missing}"
    assert log =~ "Could not delete #{stuck}"
  end

  test "a rescan skips unreadable files, keeps serving the rest, and logs each once",
       %{table: table} do
    loaded_segments = Process.whereis(LoadedSegments)
    good_id = Guardian.SegmentID.generate()
    truncated_id = Guardian.SegmentID.generate()
    empty_id = Guardian.SegmentID.generate()
    store_segment(table, good_id, [%{"a" => 1}])
    truncated = truncated_segment(table, truncated_id)
    empty = empty_segment(table, empty_id)

    log = capture_log(fn -> :ok = LoadedSegments.rescan() end)

    assert Process.whereis(LoadedSegments) == loaded_segments
    assert {:ok, _segment} = LoadedSegments.get_segment(good_id)
    assert {:error, :not_found} = LoadedSegments.get_segment(truncated_id)
    assert {:error, :not_found} = LoadedSegments.get_segment(empty_id)
    assert Enum.sort([truncated_id, empty_id]) -- LoadedSegments.skipped_segment_ids() == []
    assert BlobStore.exists(truncated) and BlobStore.exists(empty)
    assert Guardian.Storage.table_row_count(table) == 1
    assert log =~ "Skipping unreadable segment file #{truncated}"
    assert log =~ "Skipping unreadable segment file #{empty} (0 bytes"
    refute log =~ @marker

    # An unchanged file is not retried or logged again.
    assert capture_log(fn -> :ok = LoadedSegments.rescan() end) == ""
    assert {:error, :unreadable} = LoadedSegments.ensure_loaded(table, empty_id)
  end

  test "a skipped file is retried once it is replaced", %{table: table} do
    segment_id = Guardian.SegmentID.generate()
    filename = empty_segment(table, segment_id)
    capture_log(fn -> :ok = LoadedSegments.rescan() end)
    assert segment_id in LoadedSegments.skipped_segment_ids()

    # Restore a good copy the way an operator should: write elsewhere, then rename.
    ^filename = store_segment(table, segment_id, [%{"a" => 1}, %{"a" => 2}])
    :ok = LoadedSegments.rescan()

    assert {:ok, _segment} = LoadedSegments.get_segment(segment_id)
    refute segment_id in LoadedSegments.skipped_segment_ids()
    assert Guardian.Storage.table_row_count(table) == 2
  end

  test "a file that cannot be opened is retried every time and logged once", %{table: table} do
    segment_id = Guardian.SegmentID.generate()
    filename = store_segment(table, segment_id, [%{"a" => 1}])
    File.chmod!(filename, 0o000)
    on_exit(fn -> File.chmod(filename, 0o644) end)

    log = capture_log(fn -> :ok = LoadedSegments.rescan() end)
    assert log =~ "Skipping unreadable segment file #{filename}"
    assert log =~ ":eacces"
    assert segment_id in LoadedSegments.skipped_segment_ids()
    assert capture_log(fn -> :ok = LoadedSegments.rescan() end) == ""

    # Fixing the mode changes neither size, mtime, nor inode.
    File.chmod!(filename, 0o644)
    :ok = LoadedSegments.rescan()
    assert {:ok, _segment} = LoadedSegments.get_segment(segment_id)
    refute segment_id in LoadedSegments.skipped_segment_ids()
  end

  test "a skipped file whose file disappears is forgotten", %{table: table} do
    segment_id = Guardian.SegmentID.generate()
    filename = empty_segment(table, segment_id)
    capture_log(fn -> :ok = LoadedSegments.rescan() end)
    assert segment_id in LoadedSegments.skipped_segment_ids()

    :ok = BlobStore.delete(filename)
    :ok = LoadedSegments.rescan()
    refute segment_id in LoadedSegments.skipped_segment_ids()
  end

  test "expiration deletes an old skipped file", %{table: table} do
    timestamp = System.os_time(:nanosecond) - 20 * 24 * 3600 * 1_000_000_000
    old_id = Base.encode16(<<timestamp::size(64), :crypto.strong_rand_bytes(8)::binary>>)
    new_id = Guardian.SegmentID.generate()
    old_file = empty_segment(table, old_id)
    new_file = empty_segment(table, new_id)
    capture_log(fn -> :ok = LoadedSegments.rescan() end)

    Guardian.Storage.SegmentExpiration.tick()

    refute BlobStore.exists(old_file)
    refute old_id in LoadedSegments.skipped_segment_ids()
    assert BlobStore.exists(new_file)
    assert new_id in LoadedSegments.skipped_segment_ids()
  end
end

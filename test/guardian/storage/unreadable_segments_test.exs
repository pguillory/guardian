defmodule Guardian.Storage.UnreadableSegmentsTest do
  # Not async: capture_log sees every process's log events.
  use ExUnit.Case, async: false
  import Guardian.Test.Polling
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

  test "a loaded segment is linked to its loader, and dies if the loader is gone",
       %{table: table} do
    filename = store_segment(table, Guardian.SegmentID.generate(), [%{"a" => 1}])

    assert {:ok, segment} = Segment.load(filename)
    assert segment in elem(Process.info(self(), :links), 1)
    GenServer.stop(segment)

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    case GenServer.start(Segment, load: filename, owner: dead) do
      {:ok, orphan} -> eventually(fn -> not Process.alive?(orphan) end)
      {:error, _reason} -> :ok
    end
  end

  test "deleting a loaded segment whose file is gone or cannot be removed unloads it",
       %{table: table} do
    loaded_segments = Process.whereis(LoadedSegments)
    missing_id = Guardian.SegmentID.generate()
    stuck_id = Guardian.SegmentID.generate()
    missing = store_segment(table, missing_id, [%{"a" => 1}])
    stuck = store_segment(table, stuck_id, [%{"a" => 2}])
    :ok = LoadedSegments.ensure_loaded(table, missing_id)
    :ok = LoadedSegments.ensure_loaded(table, stuck_id)

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
end

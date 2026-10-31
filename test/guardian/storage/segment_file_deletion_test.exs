defmodule Guardian.Storage.SegmentFileDeletionTest do
  # Not async: capture_log sees every process's log events.
  use ExUnit.Case, async: false
  import Guardian.Test.Segments

  import ExUnit.CaptureLog

  alias Guardian.Storage.BlobStore
  alias Guardian.Storage.LoadedSegments

  setup do
    table = "file_deletion_#{System.unique_integer([:positive])}"

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

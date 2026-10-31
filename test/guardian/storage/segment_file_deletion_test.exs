defmodule Guardian.Storage.SegmentFileDeletionTest do
  # Not async: capture_log sees every process's log events.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Guardian.Storage.ReadableSegments

  test "deleting a segment whose file cannot be removed still stops it, and logs" do
    table = "file_deletion_#{System.unique_integer([:positive])}"
    :ok = Guardian.Storage.append(table, %{"a" => 1})
    Guardian.Test.Segments.await_persisted(table)
    [segment_id] = Enum.to_list(Guardian.Storage.segment_ids(table))
    {:ok, segment} = ReadableSegments.get_segment(segment_id)

    # A directory where the file was: it exists, but removing it as a file fails.
    filename = Guardian.Storage.SegmentFile.filename(table, segment_id)
    on_exit(fn -> File.rm_rf(filename) end)
    File.rm!(filename)
    File.mkdir!(filename)

    log = capture_log(fn -> :ok = Guardian.Storage.delete_segment(segment_id) end)

    refute Process.alive?(segment)
    assert ReadableSegments.get_segment(segment_id) == {:error, :not_found}
    assert log =~ "Could not delete #{filename}"
  end
end

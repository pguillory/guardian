defmodule Storage.PersistedSegmentsTest do
  alias Storage.FullSegments
  alias Storage.PersistedSegments
  alias Storage.Segment
  alias Storage.Segment.Registration
  require Registration
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  # A segment linked to the test process would die when the test ends, under the
  # persister that still holds it. Start segments from a process that exits normally
  # instead.
  defp unlinked_segment(row) do
    test = self()

    spawn(fn ->
      {:ok, segment} = Segment.start_link()
      :ok = Segment.append(segment, row)
      send(test, {:segment, segment})
    end)

    assert_receive {:segment, segment}, 1_000
    segment
  end

  describe "a segment that cannot be stored" do
    # A table name this long makes the segment's filename exceed the filesystem's
    # 255-byte name limit. Engine refuses such names now; this registers one directly,
    # as an older release or a disk fault could leave behind.
    test "is logged once, stays queryable in memory, and does not stop the persister" do
      table = String.duplicate("t", 230)
      segment_id = SegmentID.generate()
      segment = unlinked_segment(%{"v" => 1})
      registration = Registration.tuple(segment_id: segment_id, segment: segment, table: table)
      persister = Process.whereis(PersistedSegments)

      log =
        capture_log(fn ->
          :ok = FullSegments.insert(registration)

          for _ <- 1..3 do
            PersistedSegments.ping()
            :sys.get_state(PersistedSegments)
          end
        end)

      assert Process.whereis(PersistedSegments) == persister
      assert {:ok, ^segment} = FullSegments.get_segment(segment_id)
      assert segment_id in FullSegments.segment_ids(table)
      assert [_] = Regex.scan(~r/Could not persist segment #{segment_id}/, log)
      assert log =~ "enametoolong"

      # Other segments still persist.
      other = "persist_after_failure_#{System.unique_integer([:positive])}"
      other_id = SegmentID.generate()
      other_segment = unlinked_segment(%{"v" => 2})

      other_registration =
        Registration.tuple(segment_id: other_id, segment: other_segment, table: other)

      :ok = FullSegments.insert(other_registration)
      PersistedSegments.ping()
      :sys.get_state(PersistedSegments)
      assert {:ok, ^other_segment} = PersistedSegments.get_segment(other_id)
      assert File.exists?(Storage.SegmentFile.filename(other, other_id))

      :ok = FullSegments.delete(registration)
    end
  end
end

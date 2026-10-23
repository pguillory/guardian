defmodule Storage.LoadedSegmentsTest do
  alias Storage.BlobStore
  alias Storage.LoadedSegments
  alias Storage.Segment
  use ExUnit.Case, async: true
  import TestHelpers

  describe "rescan/0" do
    test "loads newly added segment files" do
      table = "rescan_test"
      segment_id = SegmentID.generate()

      # Create and persist a segment directly
      filename =
        write_segment_file(Storage.SegmentFile.filename(table, segment_id), [%{"foo" => "bar"}])

      # Verify not loaded yet
      assert {:error, :not_found} = LoadedSegments.get_segment(segment_id)

      # Rescan should pick up the new file
      :ok = LoadedSegments.rescan()

      # Now it should be loaded
      assert {:ok, loaded_segment} = LoadedSegments.get_segment(segment_id)
      assert is_pid(loaded_segment)

      # Verify the data is accessible
      assert {:ok, column} = Segment.get_column(loaded_segment, "foo")
      assert ["bar"] = Storage.Column.to_list(column)

      # Cleanup
      BlobStore.delete(filename)
    end

    test "removes segments when files are deleted" do
      table = "rescan_remove_test"
      segment_id = SegmentID.generate()

      # Create and persist a segment
      filename =
        write_segment_file(Storage.SegmentFile.filename(table, segment_id), [%{"test" => 123}])

      # Rescan to load the segment
      :ok = LoadedSegments.rescan()
      assert {:ok, loaded_segment} = LoadedSegments.get_segment(segment_id)

      # Delete the file
      :ok = BlobStore.delete(filename)

      # Rescan should remove the segment
      :ok = LoadedSegments.rescan()

      # Segment should no longer be accessible
      assert {:error, :not_found} = LoadedSegments.get_segment(segment_id)

      # The process should have been stopped
      refute Process.alive?(loaded_segment)
    end

    test "ignores legacy per-user segment files without deleting them" do
      segment_id = SegmentID.generate()

      filename =
        Path.join(
          Storage.segment_dir(),
          "4f7e7a4c-4cc9-cab7-1ee4-07adb1597c85.legacy_test.#{segment_id}.seg"
        )

      write_segment_file(filename, [%{"legacy" => true}])
      on_exit(fn -> BlobStore.delete(filename) end)

      :ok = LoadedSegments.rescan()

      assert {:error, :not_found} = LoadedSegments.get_segment(segment_id)
      assert "legacy_test" not in Storage.table_names()
      assert BlobStore.exists(filename)
    end
  end

  describe "expiration" do
    # SegmentExpiration.tick/0 expires every loaded segment older than 15 days in the
    # shared test data directory, so only the expiration test may create old IDs.
    defp old_segment_id(age_days) do
      timestamp = System.os_time(:nanosecond) - age_days * 24 * 3600 * 1_000_000_000
      Base.encode16(<<timestamp::size(64), :crypto.strong_rand_bytes(8)::binary>>)
    end

    defp store_segment(table, segment_id, rows) do
      filename = write_segment_file(Storage.SegmentFile.filename(table, segment_id), rows)
      on_exit(fn -> if BlobStore.exists(filename), do: BlobStore.delete(filename) end)
      filename
    end

    test "an expired segment is unloaded and its table disappears from metadata" do
      table = "expiration_test_#{System.unique_integer([:positive])}"
      segment_id = old_segment_id(20)
      filename = store_segment(table, segment_id, [%{"a" => 1}, %{"a" => "x"}])

      :ok = LoadedSegments.rescan()
      assert {:ok, segment} = LoadedSegments.get_segment(segment_id)
      assert table in Storage.table_names()
      assert Map.keys(Storage.schema(table)) == ["a"]

      Storage.SegmentExpiration.tick()

      refute BlobStore.exists(filename)
      assert {:error, :not_found} = LoadedSegments.get_segment(segment_id)
      refute Process.alive?(segment)
      eventually(fn -> table not in Storage.table_names() end)
      assert Storage.schema(table) == %{}
      assert Storage.table_row_count(table) == 0
    end

    test "deleting one of a table's segments keeps the rest of its metadata" do
      table = "expiration_partial_test_#{System.unique_integer([:positive])}"
      # Fresh IDs, so the expiration test's tick cannot remove them concurrently.
      old_id = SegmentID.generate()
      new_id = SegmentID.generate()
      store_segment(table, old_id, [%{"shared" => 1, "old_only" => true}])
      store_segment(table, new_id, [%{"shared" => 2}, %{"shared" => 3}])

      :ok = LoadedSegments.rescan()
      assert Map.keys(Storage.schema(table)) == ["old_only", "shared"]
      assert Storage.table_row_count(table) == 3

      :ok = LoadedSegments.delete_segment(old_id)

      eventually(fn -> Map.keys(Storage.schema(table)) == ["shared"] end)
      assert Storage.table_row_count(table) == 2
      assert table in Storage.table_names()
      assert {:ok, _segment} = LoadedSegments.get_segment(new_id)
    end
  end
end

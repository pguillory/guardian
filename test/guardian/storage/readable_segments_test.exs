defmodule Guardian.Storage.ReadableSegmentsTest do
  alias Guardian.Storage.BlobStore
  alias Guardian.Storage.Segment
  use ExUnit.Case, async: true
  import Guardian.Storage.ReadableSegments
  import Guardian.Test.Polling

  describe "expiration" do
    # SegmentExpiration.tick/0 expires every segment file older than 15 days in the
    # shared test data directory, so only these expiration tests may create old IDs.
    defp old_segment_id(age_days) do
      timestamp = System.os_time(:nanosecond) - age_days * 24 * 3600 * 1_000_000_000
      Base.encode16(<<timestamp::size(64), :crypto.strong_rand_bytes(8)::binary>>)
    end

    # A persisted segment under `segment_id`, registered as MutableSegments registers
    # a new one, so a test can choose its ID (and so its age).
    defp store_segment(table, segment_id, rows) do
      {:ok, segment} = Segment.start_supervised(segment_id: segment_id, table: table)
      :ok = insert({segment_id, segment, table})
      for row <- rows, do: :ok = Segment.append(segment, row)
      :ok = Segment.persist(segment)
      {:ok, _count} = Segment.count(segment)
      filename = Guardian.Storage.SegmentFile.filename(table, segment_id)
      on_exit(fn -> if BlobStore.exists(filename), do: BlobStore.delete(filename) end)
      {segment, filename}
    end

    test "an expired segment is stopped, its file deleted and its table gone from metadata" do
      table = "expiration_test_#{System.unique_integer([:positive])}"
      segment_id = old_segment_id(20)
      {segment, filename} = store_segment(table, segment_id, [%{"a" => 1}, %{"a" => "x"}])

      assert BlobStore.exists(filename)
      assert {:ok, ^segment} = get_segment(segment_id)
      assert table in Guardian.Storage.table_names()
      assert Map.keys(Guardian.Storage.schema(table)) == ["a"]

      Guardian.Storage.SegmentExpiration.tick()

      refute BlobStore.exists(filename)
      assert {:error, :not_found} = get_segment(segment_id)
      refute Process.alive?(segment)
      eventually(fn -> table not in Guardian.Storage.table_names() end)
      assert Guardian.Storage.schema(table) == %{}
      assert Guardian.Storage.table_row_count(table) == 0
    end

    test "an old file that was never loaded is deleted, but not a fresh one or a temp file" do
      table = "expiration_unloaded_test_#{System.unique_integer([:positive])}"
      old_id = old_segment_id(20)
      old_file = Guardian.Storage.SegmentFile.filename(table, old_id)
      old_temp_file = "#{old_file}.1.tmp"
      fresh_file = Guardian.Storage.SegmentFile.filename(table, Guardian.SegmentID.generate())
      File.mkdir_p!(Path.dirname(old_file))
      for filename <- [old_file, old_temp_file, fresh_file], do: File.write!(filename, "")
      on_exit(fn -> for file <- [old_temp_file, fresh_file], do: File.rm(file) end)

      Guardian.Storage.SegmentExpiration.tick()

      refute BlobStore.exists(old_file)
      assert BlobStore.exists(old_temp_file)
      assert BlobStore.exists(fresh_file)
    end

    test "deleting one of a table's segments keeps the rest of its metadata" do
      table = "expiration_partial_test_#{System.unique_integer([:positive])}"
      # Fresh IDs, so the expiration test's tick cannot remove them concurrently.
      old_id = Guardian.SegmentID.generate()
      new_id = Guardian.SegmentID.generate()
      store_segment(table, old_id, [%{"shared" => 1, "old_only" => true}])
      store_segment(table, new_id, [%{"shared" => 2}, %{"shared" => 3}])

      assert Map.keys(Guardian.Storage.schema(table)) == ["old_only", "shared"]
      assert Guardian.Storage.table_row_count(table) == 3

      :ok = delete_segment(old_id)

      eventually(fn -> Map.keys(Guardian.Storage.schema(table)) == ["shared"] end)
      assert Guardian.Storage.table_row_count(table) == 2
      assert table in Guardian.Storage.table_names()
      assert {:ok, _segment} = get_segment(new_id)
    end
  end
end

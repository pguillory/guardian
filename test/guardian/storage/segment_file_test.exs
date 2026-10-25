defmodule Guardian.Storage.SegmentFileTest do
  use ExUnit.Case, async: true

  alias Guardian.Storage.SegmentFile

  @segment_id "0123456789ABCDEF0123456789ABCDEF"

  describe "parse_filename/1" do
    test "parses valid segment filename" do
      filename = "events.#{@segment_id}.seg"
      assert {:ok, "events", @segment_id} = SegmentFile.parse_filename(filename)
    end

    test "parses filename with path prefix" do
      filename = "/some/path/to/segments/events.#{@segment_id}.seg"
      assert {:ok, "events", @segment_id} = SegmentFile.parse_filename(filename)
    end

    test "returns error for filename without .seg extension" do
      assert :error = SegmentFile.parse_filename("events.#{@segment_id}.txt")
    end

    test "returns error for filename with wrong number of parts" do
      assert :error = SegmentFile.parse_filename("events.seg")
      assert :error = SegmentFile.parse_filename("#{@segment_id}.seg")
    end

    test "returns error for legacy per-user filenames" do
      legacy = "4f7e7a4c-4cc9-cab7-1ee4-07adb1597c85.events.#{@segment_id}.seg"
      assert :error = SegmentFile.parse_filename(legacy)
    end

    test "returns error for malformed segment IDs" do
      assert :error = SegmentFile.parse_filename("foo.bar.seg")
      assert :error = SegmentFile.parse_filename("events.#{String.downcase(@segment_id)}.seg")
      assert :error = SegmentFile.parse_filename("events.#{@segment_id}0.seg")
      assert :error = SegmentFile.parse_filename(".#{@segment_id}.seg")
    end

    test "handles tables with special characters" do
      filename = "my_events-2.#{@segment_id}.seg"
      assert {:ok, "my_events-2", @segment_id} = SegmentFile.parse_filename(filename)
    end
  end

  describe "filename/2" do
    test "rejects a segment ID that is not a binary" do
      # Exercise invalid input at runtime without a compile-time type warning.
      assert_raise FunctionClauseError, fn -> apply(SegmentFile, :filename, ["events", 123]) end
    end

    test "generates correct filename format" do
      filename = SegmentFile.filename("events", @segment_id)
      assert String.ends_with?(filename, "/events.#{@segment_id}.seg")
    end

    test "filename is in segment directory" do
      filename = SegmentFile.filename("events", @segment_id)
      assert String.starts_with?(filename, Guardian.Storage.segment_dir())
    end

    test "round-trips with parse_filename" do
      table = "test_table"
      segment_id = Guardian.SegmentID.generate()

      filename = SegmentFile.filename(table, segment_id)
      assert {:ok, ^table, ^segment_id} = SegmentFile.parse_filename(filename)
    end
  end

  describe "unparseable/1" do
    test "reports .seg files that will be ignored, but not temp or current files" do
      legacy = "/d/4f7e7a4c-4cc9-cab7-1ee4-07adb1597c85.events.#{@segment_id}.seg"
      stray = "/d/foo.bar.seg"
      current = "/d/events.#{@segment_id}.seg"
      temp = "/d/events.#{@segment_id}.seg.123.tmp"
      other = "/d/README"

      assert SegmentFile.unparseable([legacy, stray, current, temp, other]) ==
               [legacy, stray]
    end
  end
end

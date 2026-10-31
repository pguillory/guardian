defmodule Guardian.StorageTest do
  use ExUnit.Case, async: true
  import Guardian.Storage
  import Guardian.Test.Query, only: [run_sql: 1]
  import Guardian.Test.Segments, only: [await_persisted: 1]

  alias Guardian.Storage.Segment
  require Guardian.Storage.Column.Metadata

  # Every invocation has its own table, so no test deletes the tables it fills except
  # the two that fill several segments.
  setup context do
    {:ok, table: "storage_test_#{context.test}_#{System.unique_integer([:positive])}"}
  end

  test "dump_table reconstructs multiple rows from one column", %{table: table} do
    assert_dump(table, [%{"a" => 1}, %{"a" => 2}, %{"a" => 3}])
  end

  test "dump_table reconstructs multiple columns in one row", %{table: table} do
    assert_dump(table, [%{"a" => 1, "b" => 2, "c" => 3}])
  end

  test "dump_table reconstructs sparse multi-column rows", %{table: table} do
    assert_dump(table, [
      %{},
      %{"a" => 1},
      %{"b" => 2},
      %{"a" => 3, "b" => 4},
      %{"b" => 5},
      %{},
    ])
  end

  test "append flattens a nested, atom-keyed row into dotted columns", %{table: table} do
    :ok = append(table, %{user: %{name: "Alice", tags: ["a"]}, n: 1})

    assert dump_table(table) == [
             %{"n" => 1, "user.name" => "Alice", "user.tags" => ["a"]},
           ]
  end

  # Guardian.Storage.Value accepts a map value, but no column holds one, so the segment refuses
  # it. Guardian.Storage.append would flatten the map away instead.
  test "a map value in a flattened row is refused by the segment", %{table: table} do
    assert_raise ArgumentError, "value cannot be stored", fn ->
      append_flattened(table, %{"a" => %{}})
    end

    assert append_flattened_result(table, %{"a" => %{"b" => 1}}) ==
             {:error, :invalid_value}

    assert dump_table(table) == []
  end

  test "a value no column can hold raises in the caller from every append", %{table: table} do
    for append <- [
          &append/2,
          &append_flattened/2,
          &append_flattened_result/2,
        ] do
      assert_raise MatchError, fn -> append.(table, %{"a" => [[[1]]]}) end
    end

    assert dump_table(table) == []
  end

  test "segments are read by ID", %{table: table} do
    :ok = append(table, %{"a" => 1})
    :ok = append(table, %{"b" => "x"})
    [id] = Enum.to_list(segment_ids(table))

    assert {:ok, 2} = segment_row_count(id)
    assert {:ok, a} = get_column(id, "a")
    assert Guardian.Storage.Column.to_list(a) == [1, nil]
    assert {:ok, b} = get_column(id, "b")
    assert Guardian.Storage.Column.to_list(b) == [nil, "x"]
    assert {:ok, :missing} = get_column(id, "c")
  end

  test "a segment that is gone reads as unavailable, not found", %{table: table} do
    unknown = Guardian.SegmentID.generate()

    assert {:error, {:segment_unavailable, :not_found}} =
             segment_row_count(unknown)

    assert {:error, {:segment_unavailable, :not_found}} =
             get_column(unknown, "a")

    :ok = append(table, %{"a" => 1})
    [id] = Enum.to_list(segment_ids(table))
    :ok = delete_segment(id)
    assert {:error, {:segment_unavailable, :not_found}} = segment_row_count(id)
    assert {:error, {:segment_unavailable, :not_found}} = get_column(id, "a")
  end

  test "segments have time to write their files on shutdown" do
    # Supervisors in between have no budget of their own, so a segment's is the one
    # that counts.
    {:ok, %{type: :supervisor, shutdown: :infinity}} =
      :supervisor.get_childspec(Guardian.Storage, :segments)

    [group] =
      for {:segments, pid, :supervisor, _} <- Supervisor.which_children(Guardian.Storage),
          do: pid

    {:ok, %{type: :supervisor, shutdown: :infinity}} =
      :supervisor.get_childspec(group, Guardian.Storage.SegmentSupervisor)

    %{shutdown: shutdown, restart: :temporary} = Segment.child_spec([])

    # Longer than the 5 s default, within the 150 s Fly kill_timeout less the tunnel
    # connector's drain (20 s at worst), with room for the rest of the application to stop.
    assert is_integer(shutdown) and shutdown > 5_000
    assert shutdown <= 100_000
  end

  test "list-heavy events fill segments by row count" do
    # SQL needs an addressable table name.
    table = "storage_list_rollover_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ok = delete_table(table) end)

    # 16384 rows of 5-element lists put 81,920 values in one nested layer, past the old
    # 65535 cap. The segment fills by its row count.
    count = 20_000

    for i <- 1..count do
      :ok = append(table, %{"i" => i, "tags" => [i, i + 1, i + 2, i + 3, i + 4]})
    end

    assert table_row_count(table) == count
    assert length(Enum.to_list(segment_ids(table))) >= 2

    assert [[^count]] = run_sql("select count() from #{table}")

    assert run_sql("select tags from #{table} where i > 19998") |> Enum.sort() ==
             [
               [[19_999, 20_000, 20_001, 20_002, 20_003]],
               [[20_000, 20_001, 20_002, 20_003, 20_004]],
             ]
  end

  test "large events roll over by bytes before the row capacity" do
    table = "storage_byte_rollover_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ok = delete_table(table) end)

    # About 64 KB per event reaches the 64 MiB byte budget after about 1050 events.
    count = 1500

    for i <- 1..count do
      :ok =
        append(table, %{
          "i" => i,
          "s" => String.duplicate("#{rem(i, 10)}", 64_000),
        })
    end

    assert table_row_count(table) == count
    assert length(Enum.to_list(segment_ids(table))) >= 2

    assert [[^count]] = run_sql("select count() from #{table}")

    assert run_sql("select i, s from #{table} where i = 1234") ==
             [[1234, String.duplicate("4", 64_000)]]
  end

  test "a persisted segment keeps its rows and columns", %{table: table} do
    for i <- 1..10, do: :ok = append(table, %{"i" => i, "odd" => rem(i, 2) == 1 || nil})
    :ok = append(table, %{"i" => 11, "late" => "x"})
    [segment_id] = Enum.to_list(segment_ids(table))
    before = for key <- ["i", "odd", "late"], do: get_column(segment_id, key)

    await_persisted(table)

    assert Enum.to_list(segment_ids(table)) == [segment_id]
    filename = Guardian.Storage.SegmentFile.filename(table, segment_id)
    assert segment_row_count(segment_id) == {:ok, 11}
    assert for(key <- ["i", "odd", "late"], do: get_column(segment_id, key)) == before

    # The schema registered at freezing is the file's, which counts the nils of rows
    # that lack a key (row 11 has no "odd").
    {:ok, loaded} = Segment.start_link(load: filename)
    assert schema(table) == elem(Segment.schema(loaded), 1)
    assert [Guardian.Storage.Column.Metadata.tuple(count: 11) | _] = schema(table)["odd"]
    assert table_row_count(table) == 11
  end

  test "deleting a table stops its writable and persisted segments and removes the files",
       %{table: table} do
    for v <- 1..5, do: :ok = append(table, %{"v" => v})
    await_persisted(table)
    for v <- 6..8, do: :ok = append(table, %{"v" => v})
    ids = Enum.to_list(segment_ids(table))
    assert length(ids) == 2
    files = for id <- ids, do: Guardian.Storage.SegmentFile.filename(table, id)
    assert Enum.count(files, &File.exists?/1) == 1

    :ok = delete_table(table)

    assert Enum.to_list(segment_ids(table)) == []
    refute Enum.any?(files, &File.exists?/1)
    assert table_row_count(table) == 0

    for id <- ids,
        do: assert({:error, {:segment_unavailable, :not_found}} = segment_row_count(id))
  end

  test "a segment loaded from its file registers its schema", %{table: table} do
    segment_id = Guardian.SegmentID.generate()
    filename = Guardian.Storage.SegmentFile.filename(table, segment_id)
    on_exit(fn -> File.rm(filename) end)
    File.mkdir_p!(Path.dirname(filename))
    Guardian.Test.Segments.write_segment_file(filename, [%{"a" => 1}, %{"b" => "x"}])

    {:ok, segment} =
      Segment.start_supervised(load: filename, table: table, segment_id: segment_id)

    on_exit(fn -> Segment.retire(segment) end)

    assert Map.keys(schema(table)) == ["a", "b"]

    assert [Guardian.Storage.Column.Metadata.tuple(count: 2, null_count: 1) | _] =
             schema(table)["a"]

    assert table in table_names()
  end

  test "deleting a persisted segment removes its file", %{table: table} do
    :ok = append(table, %{"a" => 1})
    [segment_id] = Enum.to_list(segment_ids(table))
    await_persisted(table)
    filename = Guardian.Storage.SegmentFile.filename(table, segment_id)
    assert File.exists?(filename)

    :ok = delete_segment(segment_id)

    refute File.exists?(filename)
    assert Enum.to_list(segment_ids(table)) == []
    assert {:error, {:segment_unavailable, :not_found}} = segment_row_count(segment_id)
  end

  test "a table stays in the schema once all its rows are persisted", %{table: table} do
    :ok = append(table, %{"a" => 1})
    await_persisted(table)

    assert Map.keys(schema(table)) == ["a"]
    assert table in table_names()
  end

  defp assert_dump(table, rows) do
    Enum.each(rows, fn row ->
      :ok = append(table, row)
    end)

    assert dump_table(table) == Enum.sort(rows)
  end
end

defmodule Guardian.StorageTest do
  use ExUnit.Case, async: false
  import Guardian.TestHelpers, only: [run_sql: 1]

  alias Guardian.Storage.MutableSegments
  alias Guardian.Storage.PersistedSegments

  setup context do
    table = "storage_test_#{context.test}"
    :ok = Guardian.Storage.delete_table(table)

    on_exit(fn ->
      :ok = Guardian.Storage.delete_table(table)
    end)

    {:ok, table: table}
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
    :ok = Guardian.Storage.append(table, %{user: %{name: "Alice", tags: ["a"]}, n: 1})

    assert Guardian.Storage.dump_table(table) == [
             %{"n" => 1, "user.name" => "Alice", "user.tags" => ["a"]},
           ]
  end

  test "a segment's refusal raises from append and append_flattened, and is returned by append_flattened_result",
       %{table: table} do
    refuse = fn from, _row -> GenServer.reply(from, {:error, :invalid_value}) end

    Guardian.TestHelpers.intercept_append(table, refuse)

    assert_raise ArgumentError, "value cannot be stored", fn ->
      Guardian.Storage.append(table, %{"a" => 1})
    end

    Guardian.TestHelpers.intercept_append(table, refuse)

    assert_raise ArgumentError, "value cannot be stored", fn ->
      Guardian.Storage.append_flattened(table, %{"a" => 1})
    end

    Guardian.TestHelpers.intercept_append(table, refuse)

    assert Guardian.Storage.append_flattened_result(table, %{"a" => 1}) ==
             {:error, :invalid_value}

    assert Guardian.Storage.dump_table(table) == []
  end

  # Guardian.Storage.Value accepts a map value, but no column holds one, so the segment refuses
  # it. Guardian.Storage.append would flatten the map away instead.
  test "a map value in a flattened row is refused by the segment", %{table: table} do
    assert_raise ArgumentError, "value cannot be stored", fn ->
      Guardian.Storage.append_flattened(table, %{"a" => %{}})
    end

    assert Guardian.Storage.append_flattened_result(table, %{"a" => %{"b" => 1}}) ==
             {:error, :invalid_value}

    assert Guardian.Storage.dump_table(table) == []
  end

  test "a value no column can hold raises in the caller from every append", %{table: table} do
    for append <- [
          &Guardian.Storage.append/2,
          &Guardian.Storage.append_flattened/2,
          &Guardian.Storage.append_flattened_result/2,
        ] do
      assert_raise MatchError, fn -> append.(table, %{"a" => [[[1]]]}) end
    end

    assert Guardian.Storage.dump_table(table) == []
  end

  test "segments are read by ID", %{table: table} do
    :ok = Guardian.Storage.append(table, %{"a" => 1})
    :ok = Guardian.Storage.append(table, %{"b" => "x"})
    [id] = Enum.to_list(Guardian.Storage.segment_ids(table))

    assert {:ok, 2} = Guardian.Storage.segment_row_count(id)
    assert {:ok, a} = Guardian.Storage.get_column(id, "a")
    assert Guardian.Storage.Column.to_list(a) == [1, nil]
    assert {:ok, b} = Guardian.Storage.get_column(id, "b")
    assert Guardian.Storage.Column.to_list(b) == [nil, "x"]
    assert {:ok, :missing} = Guardian.Storage.get_column(id, "c")
  end

  test "a segment that is gone reads as unavailable, not found", %{table: table} do
    unknown = Guardian.SegmentID.generate()

    assert {:error, {:segment_unavailable, :not_found}} =
             Guardian.Storage.segment_row_count(unknown)

    assert {:error, {:segment_unavailable, :not_found}} =
             Guardian.Storage.get_column(unknown, "a")

    :ok = Guardian.Storage.append(table, %{"a" => 1})
    [id] = Enum.to_list(Guardian.Storage.segment_ids(table))
    :ok = Guardian.Storage.delete_segment(id)
    assert {:error, {:segment_unavailable, :not_found}} = Guardian.Storage.segment_row_count(id)
    assert {:error, {:segment_unavailable, :not_found}} = Guardian.Storage.get_column(id, "a")
  end

  test "segment ID streams emit overlapping lifecycle IDs only once", %{table: table} do
    ids = [Guardian.SegmentID.generate(), Guardian.SegmentID.generate()]
    registries = [PersistedSegments, MutableSegments]
    registrations = Enum.map(ids, fn id -> {id, self(), table} end)

    on_exit(fn ->
      for registry <- registries do
        :sys.replace_state(registry, fn state ->
          Enum.each(ids, &:ets.delete(registry, &1))
          state
        end)
      end
    end)

    for registry <- registries do
      :sys.replace_state(registry, fn state ->
        true = :ets.insert(registry, registrations)
        state
      end)
    end

    all_ids = Guardian.Storage.segment_ids(table)
    unloaded_ids = Guardian.Storage.unloaded_segment_ids(table)

    assert %Stream{} = all_ids
    assert %Stream{} = unloaded_ids
    assert Enum.sort(Enum.to_list(all_ids)) == Enum.sort(ids)
    assert Enum.sort(Enum.to_list(unloaded_ids)) == Enum.sort(ids)
  end

  test "segment registries have time to persist on shutdown" do
    {:ok, %{shutdown: mutable}} = :supervisor.get_childspec(Guardian.Storage, MutableSegments)
    {:ok, %{shutdown: persisted}} = :supervisor.get_childspec(Guardian.Storage, PersistedSegments)

    # Longer than the 5 s default, within the 150 s Fly kill_timeout less the tunnel
    # connector's drain (20 s at worst), with room for the rest of the application to stop.
    assert is_integer(mutable) and mutable > 5_000
    assert is_integer(persisted) and persisted > 5_000
    assert mutable + persisted <= 100_000
  end

  test "segment registries stop in handoff order" do
    # which_children lists children in the order the supervisor stops them.
    stop_order = Supervisor.which_children(Guardian.Storage) |> Enum.map(&elem(&1, 0))
    index = &Enum.find_index(stop_order, fn id -> id == &1 end)

    assert index.(MutableSegments) < index.(PersistedSegments)
    assert index.(PersistedSegments) < index.(Guardian.Storage.FullSegments)
  end

  test "list-heavy events fill segments by row count" do
    # SQL needs an addressable table name.
    table = "storage_list_rollover"
    :ok = Guardian.Storage.delete_table(table)
    on_exit(fn -> :ok = Guardian.Storage.delete_table(table) end)

    # 16384 rows of 5-element lists put 81,920 values in one nested layer, past the old
    # 65535 cap. The segment fills by its row count.
    count = 20_000

    for i <- 1..count do
      :ok = Guardian.Storage.append(table, %{"i" => i, "tags" => [i, i + 1, i + 2, i + 3, i + 4]})
    end

    assert Guardian.Storage.table_row_count(table) == count
    assert length(Enum.to_list(Guardian.Storage.segment_ids(table))) >= 2

    for segment <- MutableSegments.get_mutable_segments(table) do
      :ok = MutableSegments.segment_is_full(table, segment)
    end

    :sys.get_state(PersistedSegments)
    :ok = Guardian.Storage.LoadedSegments.rescan()

    assert [[^count]] = run_sql("select count() from #{table}")

    assert run_sql("select tags from #{table} where i > 19998") |> Enum.sort() ==
             [
               [[19_999, 20_000, 20_001, 20_002, 20_003]],
               [[20_000, 20_001, 20_002, 20_003, 20_004]],
             ]
  end

  test "large events roll over by bytes before the row capacity" do
    table = "storage_byte_rollover_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ok = Guardian.Storage.delete_table(table) end)

    # About 64 KB per event reaches the 64 MiB byte budget after about 1050 events.
    count = 1500

    for i <- 1..count do
      :ok =
        Guardian.Storage.append(table, %{
          "i" => i,
          "s" => String.duplicate("#{rem(i, 10)}", 64_000),
        })
    end

    assert Guardian.Storage.table_row_count(table) == count
    assert length(Enum.to_list(Guardian.Storage.segment_ids(table))) >= 2

    for segment <- MutableSegments.get_mutable_segments(table) do
      :ok = MutableSegments.segment_is_full(table, segment)
    end

    :sys.get_state(PersistedSegments)
    :ok = Guardian.Storage.LoadedSegments.rescan()

    assert [[^count]] = run_sql("select count() from #{table}")

    assert run_sql("select i, s from #{table} where i = 1234") ==
             [[1234, String.duplicate("4", 64_000)]]
  end

  # LoadedSegments' minute scan once loaded a segment that PersistedSegments still
  # cached while the byte-rollover test above counted, and the old count added it twice.
  test "table_row_count counts a segment once while it is cached and loaded", %{table: table} do
    for i <- 1..10, do: :ok = Guardian.Storage.append(table, %{"i" => i})

    for segment <- MutableSegments.get_mutable_segments(table) do
      :ok = MutableSegments.segment_is_full(table, segment)
    end

    :ok = PersistedSegments.ping()
    :sys.get_state(PersistedSegments)
    :ok = Guardian.Storage.LoadedSegments.rescan()

    [segment_id] = Enum.to_list(Guardian.Storage.segment_ids(table))
    assert segment_id in PersistedSegments.segment_ids(table)
    assert segment_id in Guardian.Storage.LoadedSegments.segment_ids(table)
    assert Guardian.Storage.table_row_count(table) == 10
  end

  defp assert_dump(table, rows) do
    Enum.each(rows, fn row ->
      :ok = Guardian.Storage.append(table, row)
    end)

    assert Guardian.Storage.dump_table(table) == Enum.sort(rows)
  end
end

defmodule Storage.SegmentFileGoldenTest do
  use ExUnit.Case, async: true

  alias Storage.Column
  alias Storage.Segment

  # test/fixtures/segment_file.seg is the segment file that `rows/0` produced on
  # 2026-10-18. Persisted segments must keep
  # reading the same and new ones must be written byte-for-byte the same; changing the
  # format needs an explicit migration plan (lib/storage/CLAUDE.md). Packed columns are
  # in host byte order, so the fixture matches only on little-endian machines (arm64
  # Macs and x86_64 Fly machines are).
  @fixture Path.expand("../fixtures/segment_file.seg", __DIR__)

  @primary_header_size 9 * 8

  @keys ["kind", "list", "n", "nested.a", "nested.b.c", "nothing", "sparse"]

  # Every value kind a column stores, a key present in only some rows, a column that
  # holds only nils, a nested map (flattened to dot keys), and more than 64 rows so
  # bitmaps span several words. Keep it to 32 keys or fewer: the file stores columns in
  # map order, which is sorted only for small maps.
  defp rows do
    [
      %{"kind" => nil, "n" => 0, "nothing" => nil},
      %{"kind" => false, "n" => -1},
      %{"kind" => true, "n" => 9_223_372_036_854_775_807},
      %{"kind" => 1.5, "n" => -0.25, "sparse" => "only here"},
      %{"kind" => "", "nested" => %{"a" => 1, "b" => %{"c" => "deep"}}},
      %{"kind" => "hello", "list" => ["a", 1, [2, "b"], []]},
      %{"kind" => [[nil, true]], "n" => 42},
    ] ++ Enum.map(1..70, &%{"n" => &1, "kind" => if(rem(&1, 3) == 0, do: "s#{&1}", else: &1)})
  end

  # `get_row` omits a nil value as it does an absent key.
  defp expected_row(row) do
    row
    |> Storage.Flattening.flatten_event()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Storage.Flattening.unflatten_event()
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "segment_file_golden_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "a stored segment matches the checked-in file", %{dir: dir} do
    {:ok, segment} = Segment.start_link()
    Enum.each(rows(), &(:ok = TestHelpers.segment_append(segment, &1)))
    :ok = Segment.pack(segment)
    filename = Path.join(dir, "golden.seg")
    :ok = Segment.store(segment, filename)
    GenServer.stop(segment)

    assert File.read!(filename) == File.read!(@fixture)
  end

  test "the checked-in file loads with the same rows", %{dir: dir} do
    filename = Path.join(dir, "golden.seg")
    File.cp!(@fixture, filename)

    {:ok, segment} = Segment.load(filename)
    count = length(rows())

    assert {:ok, ^count} = Segment.count(segment)
    assert {:ok, true} = Segment.full(segment)

    assert {:ok, keys} = Segment.keys(segment)

    assert Enum.sort(keys) == @keys

    for {row, offset} <- Enum.with_index(rows()) do
      assert {:ok, expected_row(row)} === Segment.get_row(segment, offset)
    end

    assert {:ok, column} = Segment.get_column(segment, "n")
    assert Column.to_list(column) === Enum.map(rows(), & &1["n"])

    # The same column metadata (types and counts) as the segment it was written from.
    {:ok, original} = Segment.start_link()
    Enum.each(rows(), &(:ok = TestHelpers.segment_append(original, &1)))
    :ok = Segment.pack(original)
    assert Segment.schema(segment) === Segment.schema(original)
    GenServer.stop(original)

    GenServer.stop(segment)
  end

  # Pins the header layout, so a fixture difference can be explained: nine big-endian
  # 64-bit integers (the row count, then the sizes of the keys column, the six per-type
  # count columns and the column-sizes column), those eight columns, then each packed
  # column in key order.
  test "the checked-in file has the documented layout" do
    data = File.read!(@fixture)

    <<count::size(64), header_sizes::binary-size(@primary_header_size - 8), _::binary>> = data
    sizes = for <<size::size(64) <- header_sizes>>, do: size
    assert count == length(rows())
    assert length(sizes) == 8

    secondary = binary_part(data, @primary_header_size, Enum.sum(sizes))

    {columns, <<>>} =
      Enum.map_reduce(sizes, secondary, fn size, rest ->
        <<column::binary-size(size), rest::binary>> = rest
        {Column.to_list(column), rest}
      end)

    [keys, _null, _false, _true, _int, _float, _string, column_sizes] = columns
    assert keys == @keys
    assert length(column_sizes) == length(keys)

    assert byte_size(data) ==
             @primary_header_size + Enum.sum(sizes) + Enum.sum(column_sizes)
  end
end

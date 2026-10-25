defmodule Guardian.Storage.ColumnGoldenTest do
  use ExUnit.Case, async: true
  alias Guardian.Storage.Column

  # test/fixtures/column_nif_outputs.etf holds these outputs as produced by the column
  # NIF before its arithmetic moved to 64-bit types (column-64bit-arithmetic). Packed
  # columns are the segment file format, so they must stay byte-for-byte identical.
  # `add` and `multiply` were regenerated when a non-number on the left stopped
  # shifting the right side's later values (their old outputs paired wrong rows).
  @fixture Path.expand("../fixtures/column_nif_outputs.etf", __DIR__)

  test "column NIF outputs match the checked-in fixture" do
    expected = @fixture |> File.read!() |> :erlang.binary_to_term()
    actual = outputs()

    assert Keyword.keys(actual) == Keyword.keys(expected)

    for {name, value} <- actual do
      assert value === Keyword.fetch!(expected, name), "#{name} changed"
    end
  end

  # More than 64 rows, so bitmaps span several words and end in a partial word, with
  # nested lists spread across them.
  defp outputs do
    values =
      [
        nil,
        false,
        true,
        0,
        -1,
        9_223_372_036_854_775_807,
        1.5,
        -0.25,
        "",
        "hello",
        ["a", 1, [2, "b"], []],
        [[nil, true]],
        42,
      ] ++ Enum.map(1..70, &if(rem(&1, 3) == 0, do: [&1, "s#{&1}"], else: &1))

    n = length(values)
    col = Column.from_list(values)
    mask = Column.from_list(Enum.map(1..n, &(rem(&1, 2) == 0)))
    bools = Column.from_list(Enum.map(1..n, &Enum.at([true, false, nil], rem(&1, 3))))
    nums = Column.from_list(Enum.map(1..n, &if(rem(&1, 4) == 0, do: &1 * 0.5, else: &1)))
    mutable = Column.new(4)
    Enum.each(values, &Column.append(mutable, &1))

    [
      from_list: col,
      pack: Column.pack(mutable),
      padded: Column.new(1) |> Column.pad(130) |> Column.pack(),
      filter: Column.filter(col, mask),
      to_string: Column.to_string(col),
      to_boolean: Column.to_boolean(col),
      add: Column.add(col, nums),
      subtract: Column.subtract(nums, col),
      multiply: Column.multiply(col, nums),
      divide: Column.divide(nums, nums),
      and: Column.and_oper(bools, mask),
      or: Column.or_oper(bools, mask),
      not: Column.not_oper(bools),
      number_to_true: Column.number_to_true(col),
      number_to_false: Column.number_to_false(col),
      min_max: Column.min_max_number(nums),
      metadata: Column.metadata(col),
      to_list: Column.to_list(col),
      counts:
        Enum.map(
          [
            :count,
            :null_count,
            :false_count,
            :true_count,
            :int_count,
            :float_count,
            :string_count,
          ],
          &apply(Column, &1, [col])
        ),
    ]
  end
end

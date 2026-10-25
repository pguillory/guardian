defmodule Guardian.Storage.ColumnTest do
  alias Guardian.Storage.Column
  import Column
  use ExUnit.Case, async: true

  test "new" do
    assert catch_error(new(-1)) == :badarg
    assert new() |> is_reference()
    assert new(0) |> is_reference()
    assert new(1) |> is_reference()
    assert new(65536) |> is_reference()
    assert new(100_000) |> pad(100_000) |> count() == 100_000
    assert catch_error(new(2 ** 40 + 1)) == :badarg
    assert catch_error(new(2 ** 64 - 1)) == :badarg
    assert catch_error(new(2 ** 64)) == :badarg
  end

  test "append" do
    column = new()
    :ok = append(column, nil)
    assert column |> to_list() === [nil]
  end

  test "pack" do
    column = new()
    :ok = append(column, 123)
    assert column |> pack() |> to_list() === [123]
  end

  describe "resize" do
    test "pads, cuts, or keeps a packed column" do
      packed = from_list([1, "a", [2.5]])
      padded = resize(packed, 5)
      assert is_binary(padded)
      assert to_list(padded) === [1, "a", [2.5], nil, nil]
      assert packed |> resize(2) |> to_list() === [1, "a"]
      assert resize(packed, 3) === packed
      assert from_list([]) |> resize(2) |> to_list() === [nil, nil]
      assert from_list([nil]) |> resize(3) |> to_list() === [nil, nil, nil]
    end

    # A mutable column is padded in place: the caller's column grows too.
    test "pads or cuts a mutable column" do
      column = new()
      :ok = append(column, 1)
      :ok = append(column, 2)
      padded = resize(column, 3)
      assert is_binary(padded)
      assert to_list(padded) === [1, 2, nil]
      assert to_list(column) === [1, 2, nil]

      column = new()
      :ok = append(column, 1)
      :ok = append(column, 2)
      assert column |> resize(1) |> to_list() === [1]
    end
  end

  test "pad" do
    assert new(5) |> pad(2) |> to_list() === [nil, nil]
    assert new(5) |> pad(5) |> to_list() === [nil, nil, nil, nil, nil]
    assert new(5) |> pad(6) |> to_list() === [nil, nil, nil, nil, nil, nil]
  end

  defmacro from_to_list(list) do
    quote location: :keep do
      assert unquote(list) |> from_list() |> to_list() == unquote(list)
    end
  end

  test "from/to list" do
    from_to_list([])

    from_to_list([nil])
    from_to_list([false])
    from_to_list([true])
    from_to_list([123])
    from_to_list([4.5])
    from_to_list(["abc"])

    from_to_list([[nil]])
    from_to_list([[false]])
    from_to_list([[true]])
    from_to_list([[123]])
    from_to_list([[4.5]])
    from_to_list([["abc"]])

    from_to_list(List.duplicate(nil, 10000))
    from_to_list(List.duplicate(false, 10000))
    from_to_list(List.duplicate(true, 10000))
    from_to_list(List.duplicate(123, 10000))
    from_to_list(List.duplicate(4.5, 10000))
    from_to_list(List.duplicate("abc", 10000))

    from_to_list(List.duplicate([nil], 10000))
    from_to_list(List.duplicate([false], 10000))
    from_to_list(List.duplicate([true], 10000))
    from_to_list(List.duplicate([123], 10000))
    from_to_list(List.duplicate([4.5], 10000))
    from_to_list(List.duplicate(["abc"], 10000))

    from_to_list(List.duplicate([nil, false, true, 123, 4.5, "abc"], 1000))
  end

  test "filter" do
    column1 = from_list([nil, nil, nil])
    column2 = from_list([false, true, false])
    assert filter(column1, column2) |> to_list() === [nil]

    column1 = from_list([false, false, false])
    column2 = from_list([false, true, false])
    assert filter(column1, column2) |> to_list() === [false]

    column1 = from_list([true, true, true])
    column2 = from_list([false, true, false])
    assert filter(column1, column2) |> to_list() === [true]

    column1 = from_list([123, 234, 345])
    column2 = from_list([false, true, false])
    assert filter(column1, column2) |> to_list() === [234]

    column1 = from_list([4.5, 5.6, 6.7])
    column2 = from_list([false, true, false])
    assert filter(column1, column2) |> to_list() === [5.6]

    column1 = from_list(["a", "b", "c"])
    column2 = from_list([false, true, false])
    assert filter(column1, column2) |> to_list() === ["b"]
  end

  test "add" do
    column1 = from_list([123, 4.5, 123, 4.5])
    column2 = from_list([123, 123, 4.5, 4.5])
    assert add(column1, column2) |> to_list() === [246, 127.5, 127.5, 9.0]

    column1 = from_list([123, nil, 123, nil])
    column2 = from_list([123, 123, nil, nil])
    assert add(column1, column2) |> to_list() === [246, nil, nil, nil]

    column1 = from_list([nil, 4.5, nil, 4.5])
    column2 = from_list([nil, nil, 4.5, 4.5])
    assert add(column1, column2) |> to_list() === [nil, nil, nil, 9.0]
  end

  test "subtract" do
    column1 = from_list([123, 4.5, 123, 4.5])
    column2 = from_list([123, 123, 4.5, 4.5])
    assert subtract(column1, column2) |> to_list() === [0, -118.5, 118.5, 0.0]

    column1 = from_list([123, nil, 123, nil])
    column2 = from_list([123, 123, nil, nil])
    assert subtract(column1, column2) |> to_list() === [0, nil, nil, nil]

    column1 = from_list([nil, 4.5, nil, 4.5])
    column2 = from_list([nil, nil, 4.5, 4.5])
    assert subtract(column1, column2) |> to_list() === [nil, nil, nil, 0.0]
  end

  test "multiply" do
    column1 = from_list([123, 4.5, 123, 4.5])
    column2 = from_list([123, 123, 4.5, 4.5])
    assert multiply(column1, column2) |> to_list() === [15129, 553.5, 553.5, 20.25]

    column1 = from_list([123, nil, 123, nil])
    column2 = from_list([123, 123, nil, nil])
    assert multiply(column1, column2) |> to_list() === [15129, nil, nil, nil]

    column1 = from_list([nil, 4.5, nil, 4.5])
    column2 = from_list([nil, nil, 4.5, 4.5])
    assert multiply(column1, column2) |> to_list() === [nil, nil, nil, 20.25]
  end

  test "divide" do
    column1 = from_list([123, 4.5, 123, 4.5])
    column2 = from_list([123, 123, 4.5, 4.5])

    assert divide(column1, column2) |> to_list() === [
             1.0,
             0.036585365853658534,
             27.333333333333332,
             1.0,
           ]

    column1 = from_list([123, nil, 123, nil])
    column2 = from_list([123, 123, nil, nil])
    assert divide(column1, column2) |> to_list() === [1.0, nil, nil, nil]

    column1 = from_list([nil, 4.5, nil, 4.5])
    column2 = from_list([nil, nil, 4.5, 4.5])
    assert divide(column1, column2) |> to_list() === [nil, nil, nil, 1.0]
  end

  test "a non-number on the left doesn't shift the right side's later values" do
    left = from_list([nil, 1, "x", 2.5, true, 3])
    right = from_list([10, 20, 30.5, 40, 50, 60])
    assert add(left, right) |> to_list() === [nil, 21, nil, 42.5, nil, 63]
    assert subtract(left, right) |> to_list() === [nil, -19, nil, -37.5, nil, -57]
    assert multiply(left, right) |> to_list() === [nil, 20, nil, 100.0, nil, 180]
    assert divide(left, right) |> to_list() === [nil, 0.05, nil, 0.0625, nil, 0.05]
  end

  test "arithmetic results that aren't finite are null, never stored" do
    assert divide(from_list([1, 0, -1, 1.5, 0.0]), from_list([0, 0, 0, 0.0, 0])) |> to_list() ===
             [nil, nil, nil, nil, nil]

    assert add(from_list([1.0e308, 1, 2]), from_list([1.0e308, 1, 3])) |> to_list() === [
             nil,
             2,
             5,
           ]

    assert subtract(from_list([-1.0e308, 5]), from_list([1.0e308, 2])) |> to_list() === [nil, 3]

    assert multiply(from_list([1.0e200, 2.5]), from_list([1.0e200, 2])) |> to_list() === [
             nil,
             5.0,
           ]

    assert divide(from_list([1.0e308, 6]), from_list([1.0e-308, 3])) |> to_list() === [nil, 2.0]
  end

  test "min_max_number" do
    assert from_list([1, 2, 3]) |> min_max_number() === {1, 3}
    assert from_list([nil, 2, 3]) |> min_max_number() === {2, 3}
    assert from_list([1, nil, 3]) |> min_max_number() === {1, 3}
    assert from_list([1, 2, nil]) |> min_max_number() === {1, 2}
    assert from_list([nil, nil, nil]) |> min_max_number() === {nil, nil}

    assert from_list([1.0, 2.0, 3.0]) |> min_max_number() === {1.0, 3.0}
    assert from_list([nil, 2.0, 3.0]) |> min_max_number() === {2.0, 3.0}
    assert from_list([1.0, nil, 3.0]) |> min_max_number() === {1.0, 3.0}
    assert from_list([1.0, 2.0, nil]) |> min_max_number() === {1.0, 2.0}
    assert from_list([nil, nil, nil]) |> min_max_number() === {nil, nil}

    assert from_list([1, 2.0, 3.0]) |> min_max_number() === {1, 3.0}
    assert from_list([1.0, 2.0, 3]) |> min_max_number() === {1.0, 3}

    # Fractional and negative floats keep their exact value.
    assert from_list([2.5]) |> min_max_number() === {2.5, 2.5}
    assert from_list([-0.5, 1.25]) |> min_max_number() === {-0.5, 1.25}
    assert from_list([1, 2.5]) |> min_max_number() === {1, 2.5}
    assert from_list([3, -0.5]) |> min_max_number() === {-0.5, 3}
    assert from_list([1.0e20, -1.0e20]) |> min_max_number() === {-1.0e20, 1.0e20}

    # Ints and floats compare exactly, also above 2^53, where a double cannot hold
    # every int64. An int equal to a float bound wins.
    big = 9_007_199_254_740_993

    assert from_list([big, 9_007_199_254_740_992.0]) |> min_max_number() ===
             {9_007_199_254_740_992.0, big}

    assert from_list([-big, -9_007_199_254_740_992.0]) |> min_max_number() ===
             {-big, -9_007_199_254_740_992.0}

    assert from_list([big - 2, 9_007_199_254_740_992.0]) |> min_max_number() ===
             {big - 2, 9_007_199_254_740_992.0}

    assert from_list([9_223_372_036_854_775_807, 9.223372036854775807e18]) |> min_max_number() ===
             {9_223_372_036_854_775_807, 9.223372036854775807e18}

    assert from_list([-9_223_372_036_854_775_808, -9.223372036854775808e18]) |> min_max_number() ===
             {-9_223_372_036_854_775_808, -9_223_372_036_854_775_808}

    assert from_list([0, -1.0e20]) |> min_max_number() === {-1.0e20, 0}
    assert from_list([0, 1.0e20]) |> min_max_number() === {0, 1.0e20}
    assert from_list([3, 3.0]) |> min_max_number() === {3, 3}
    assert from_list([3, 2.5, 3.5]) |> min_max_number() === {2.5, 3.5}
    assert from_list([-3, -2.5, -3.5]) |> min_max_number() === {-3.5, -2.5}
  end

  test "to_boolean" do
    assert from_list([nil]) |> to_boolean() |> to_list() == [nil]
    assert from_list([false]) |> to_boolean() |> to_list() == [false]
    assert from_list([true]) |> to_boolean() |> to_list() == [true]
    assert from_list([123]) |> to_boolean() |> to_list() == [nil]
    assert from_list([4.5]) |> to_boolean() |> to_list() == [nil]
    assert from_list(["abc"]) |> to_boolean() |> to_list() == [nil]
  end

  describe "filter with list values" do
    defp assert_filter(values, keep) do
      mask = from_list(keep)
      expected = values |> Enum.zip(keep) |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

      packed = from_list(values)
      assert filter(packed, mask) |> to_list() === expected

      # Mutable columns take a different path into the NIF than packed binaries.
      mutable = new(length(values))
      Enum.each(values, &(:ok = append(mutable, &1)))
      assert filter(mutable, mask) |> to_list() === expected

      # The result must be a well-formed packed column usable by other operations.
      filtered = filter(packed, mask)
      assert filtered |> to_list() |> from_list() === filtered
      assert count(filtered) == length(expected)
      assert filter(filtered, from_list(List.duplicate(true, length(expected)))) === filtered
    end

    test "keeps a list row" do
      assert_filter([nil, ["x", "y"]], [false, true])
      assert_filter([["x", "y"], nil], [true, false])
    end

    test "drops a list row" do
      assert_filter([nil, ["x", "y"]], [true, false])
      assert_filter([1, ["x", "y"], 2], [true, false, true])
    end

    test "keeps some list rows and drops others" do
      assert_filter([["a"], ["b", "c"], ["d", "e", "f"], ["g"]], [false, true, false, true])
      assert_filter([["a"], ["b", "c"], ["d", "e", "f"], ["g"]], [true, false, true, false])
    end

    test "nested lists" do
      assert_filter([[["a"]], [[1, 2], []], nil, [[], [true]]], [false, true, false, true])
      assert_filter([[["a"]], [[1, 2], []], nil, [[], [true]]], [true, false, true, false])
      assert_filter([[["a"]], [[1, 2], []], nil, [[], [true]]], [false, false, true, false])
      assert_filter([[1, [2, 3]], [[4], 5]], [false, true])
    end

    test "lists mixed with other types" do
      values = [nil, false, true, 1, 2.5, "s", [nil, false, true, 1, 2.5, "s"], [], [[]]]

      for keep <- [
            [false, true, false, true, false, true, false, true, false],
            [true, false, true, false, true, false, true, false, true],
            [false, false, false, false, false, false, true, false, false],
            [false, false, false, false, false, false, false, true, true],
          ] do
        assert_filter(values, keep)
      end
    end

    test "empty lists" do
      assert_filter([[], [], []], [false, true, false])
      assert_filter([[], ["a"], []], [true, false, true])
      assert_filter([[[]], [[]]], [false, true])
    end

    test "treats null and false mask values as dropped" do
      column = from_list([["a"], ["b"], ["c"]])
      assert filter(column, from_list([nil, true, false])) |> to_list() === [["b"]]
    end

    test "many rows across bitmap words" do
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..20 do
        values =
          for _ <- 1..300 do
            Enum.random([
              nil,
              :rand.uniform(100),
              "s",
              [],
              [:rand.uniform(100), "x"],
              [[1], [], ["y", nil]],
            ])
          end

        keep = for _ <- values, do: :rand.uniform(2) == 1
        assert_filter(values, keep)
      end
    end
  end

  describe "rejecting values without corrupting the column" do
    defp assert_append_rejected(value) do
      column = new(4)
      :ok = append(column, ["before"])
      assert catch_error(append(column, value)) == :badarg
      :ok = append(column, ["after"])
      assert column |> pack() |> to_list() === [["before"], ["after"]]
      assert column |> to_list() === [["before"], ["after"]]

      assert catch_error(from_list([["ok"], value])) == :badarg
    end

    test "unsupported values inside lists" do
      assert_append_rejected([1, %{}])
      assert_append_rejected([%{}])
      assert_append_rejected([[1, :atom]])
      assert_append_rejected([{1, 2}])
      assert_append_rejected([1 | 2])
    end

    test "lists nested too deeply" do
      # A column of lists of lists is the deepest supported shape.
      assert max_list_depth() == 3
      assert from_list([[[1]]]) |> to_list() === [[[1]]]
      assert_append_rejected([[[1]]])
      assert_append_rejected([[], [[["deep"]]]])
    end

    test "empty strings" do
      assert from_list(["", [""], "a"]) |> to_list() === ["", [""], "a"]
      assert from_list(["", 1]) |> Guardian.Storage.Column.to_string() |> to_list() === ["", nil]
    end

    test "counts no column can have" do
      assert catch_error(new(1) |> pad(2 ** 40 + 1)) == :badarg
      assert catch_error(new(1) |> pad(2 ** 64 - 1)) == :badarg
      assert catch_error(new(1) |> pad(-1)) == :badarg
    end
  end

  describe "past the old column limits" do
    test "limits come from the packed format" do
      assert max_string_size() == 2 ** 31 - 1
      assert max_list_length() == 2 ** 31 - 1
    end

    test "many rows" do
      assert from_list(List.duplicate(nil, 100_000)) |> count() == 100_000
      assert new(1) |> pad(100_000) |> pack() |> to_list() == List.duplicate(nil, 100_000)

      values = Enum.to_list(1..100_000)
      assert values |> from_list() |> to_list() == values
      assert values |> from_list_slow() |> to_list() == values
    end

    test "a long string and a long list" do
      string = String.duplicate("s", 1_000_000)
      list = Enum.to_list(1..100_000)
      values = [string, list, nil, [string], 1]
      mask = from_list([true, true, false, true, false])

      mutable = new(0)
      Enum.each(values, &(:ok = append(mutable, &1)))
      packed = pack(mutable)

      for column <- [mutable, packed, from_list(values)] do
        assert to_list(column) === values
        assert column |> filter(mask) |> to_list() === [string, list, [string]]

        assert column |> Guardian.Storage.Column.to_string() |> to_list() === [
                 string,
                 nil,
                 nil,
                 nil,
                 nil,
               ]
      end
    end

    test "a nested layer with more than 65535 elements" do
      lists = [List.duplicate(1, 40_000), List.duplicate(2, 40_000), [3]]
      mask = from_list([true, false, true])

      mutable = new(0)
      Enum.each(lists, &(:ok = append(mutable, &1)))

      for column <- [mutable, pack(mutable), from_list(lists)] do
        assert to_list(column) === lists
        assert column |> filter(mask) |> to_list() === [List.duplicate(1, 40_000), [3]]
      end

      assert [_, {80_001, _, _, _, _, _, _, _}] = metadata(pack(mutable))
    end

    # About 2 GB peak. Run by hand with `mix test --only large`.
    @tag :large
    @tag timeout: :infinity
    test "a layer with more than 2^28 string bytes" do
      # 270 strings of 1 MiB, nested in one list so they share a layer.
      strings = List.duplicate(String.duplicate("s", 1024 * 1024), 270)
      column = new(0)
      :ok = append(column, strings)
      :ok = append(column, "top")
      packed = pack(column)
      assert byte_size(packed) > 2 ** 28
      assert [^strings, "top"] = to_list(packed)
    end

    test "empty columns" do
      for column <- [new(0), new(0) |> pack(), from_list([])] do
        assert to_list(column) == []
        assert count(column) == 0
        assert column |> Guardian.Storage.Column.to_string() |> to_list() == []
        assert column |> filter(from_list([])) |> to_list() == []
      end

      assert new(0) |> pad(0) |> pack() |> to_list() == []
    end

    @tag :large
    @tag timeout: :infinity
    test "a layer with more than 2^31 string bytes" do
      # About 2.2 GB. The case that int arithmetic got wrong; run by hand with
      # `mix test --only large`.
      string = String.duplicate("s", 64 * 1024 * 1024)
      strings = List.duplicate(string, 33)
      column = new(0)
      :ok = append(column, strings)
      packed = pack(column)
      assert byte_size(packed) > 2 ** 31
      assert [values] = to_list(packed)
      assert length(values) == 33
      assert Enum.all?(values, &(&1 == string))
    end
  end

  describe "sizes" do
    @size_samples [
      [],
      [nil],
      [1, 2.5, true, false, nil],
      ["", "a", "abc", String.duplicate("x", 1000)],
      [["a", "bb"], [], [1, [2, "c"], []], nil, "s"],
      Enum.to_list(1..130),
    ]

    test "packed_size is the size of the packed column" do
      for values <- @size_samples do
        mutable = new(0)
        Enum.each(values, &(:ok = append(mutable, &1)))
        packed = pack(mutable)
        assert packed_size(mutable) == byte_size(packed), inspect(values)
        assert packed_size(packed) == byte_size(packed), inspect(values)
        assert packed_size(from_list(values)) == byte_size(packed), inspect(values)
      end
    end

    test "nil_column_size is the packed size of a column of nils" do
      for count <- [0, 1, 63, 64, 65, 128, 130, 16_384] do
        assert nil_column_size(count) == byte_size(from_list(List.duplicate(nil, count)))
      end
    end

    test "padding grows a column's packed size by exactly the nil column size" do
      for values <- @size_samples do
        column = from_list(values)
        value_size = packed_size(column) - nil_column_size(count(column))

        for padded_count <- [length(values) + 1, 64, 200, 5000], padded_count >= length(values) do
          padded = new(0)
          Enum.each(values, &(:ok = append(padded, &1)))
          padded = pad(padded, padded_count)
          assert packed_size(padded) - nil_column_size(padded_count) == value_size
        end
      end
    end

    test "a mostly nil column holds little more memory than its packed size" do
      # Value arrays grow with their own counts, not with the row count.
      for value <- [1, 1.5, "s", [1, 2]] do
        column = new(0) |> pad(16_383)
        :ok = append(column, value)
        assert allocated_size(column) <= 2 * packed_size(column) + 1024, inspect(value)
      end
    end

    test "growing columns stay within twice their packed size" do
      for value <- [1, 1.5, "s", [1, "a", [2.5]], true] do
        column = new(0)

        for _ <- 1..10_000 do
          :ok = append(column, value)
        end

        assert column |> pack() |> to_list() == List.duplicate(value, 10_000)
        assert allocated_size(column) <= 2 * packed_size(column) + 1024, inspect(value)
      end
    end

    test "allocated_size only takes mutable columns" do
      assert catch_error(allocated_size(from_list([1]))) == :badarg
    end
  end

  describe "valid_value?" do
    # Built at run time: as a module attribute, these values would be compiled in as
    # literals of hundreds of megabytes.
    defp candidates do
      [
        nil,
        false,
        true,
        0,
        -9_223_372_036_854_775_808,
        9_223_372_036_854_775_807,
        9_223_372_036_854_775_808,
        1.5,
        "",
        "s",
        String.duplicate("a", 65_535),
        String.duplicate("a", 100_000),
        [],
        [[]],
        [[[]]],
        [1, [2, "x"], []],
        [[[1]]],
        [1 | 2],
        [%{}],
        %{},
        :atom,
        {1},
        List.duplicate(1, 65_535),
        List.duplicate(1, 100_000),
        [List.duplicate(1, 40_000), List.duplicate(1, 30_000)],
        List.duplicate(String.duplicate("a", 65_535), 100),
      ]
    end

    test "agrees with append on an empty column" do
      for value <- candidates() do
        column = new(1)
        appended = append_result(column, value)
        assert valid_value?(value) == appended, inspect(value, limit: 3)
      end
    end

    test "agrees with append on a partly full column" do
      column = new(4)
      :ok = append(column, List.duplicate("b", 30_000))
      :ok = append(column, [String.duplicate("c", 65_535)])

      # Columns have no size caps, so a partly full column accepts exactly the values
      # an empty one does.
      for value <- candidates() do
        scratch = column |> to_list() |> copy_to_mutable()
        assert append_result(scratch, value) == valid_value?(value), inspect(value, limit: 3)
      end

      assert column |> to_list() |> length() == 2
    end

    defp append_result(column, value) do
      try do
        :ok = append(column, value)
        true
      rescue
        ArgumentError -> false
      end
    end

    defp copy_to_mutable(values) do
      column = new(4)
      Enum.each(values, &(:ok = append(column, &1)))
      column
    end
  end
end

defmodule Storage.FlatteningTest do
  use ExUnit.Case
  import Storage.Flattening

  defp assert_columns(events, expected_columns) do
    virtual_segment = from_events(events)
    assert virtual_segment.columns == expected_columns
    assert virtual_segment.count == length(events)
  end

  defp assert_round_trip(events) do
    result = events |> from_events() |> to_events()
    assert result == events
  end

  defp assert_flatten_event(event, expected) do
    assert flatten_event(event) == expected
    assert unflatten_event(expected) == event
  end

  describe "map_update" do
    test "updates existing key with function" do
      assert map_update(%{a: 1}, :a, 0, &(&1 + 10)) == %{a: 11}
      assert map_update(%{a: [1, 2]}, :a, [], &(&1 ++ [3])) == %{a: [1, 2, 3]}
    end

    test "uses default when key missing" do
      assert map_update(%{}, :a, 0, &(&1 + 10)) == %{a: 10}
      assert map_update(%{b: 1}, :a, 100, &(&1 * 2)) == %{a: 200, b: 1}
    end

    test "works with various value types" do
      assert map_update(%{}, :count, 0, &(&1 + 1)) == %{count: 1}
      assert map_update(%{}, :list, [], &[1 | &1]) == %{list: [1]}
      assert map_update(%{}, :str, "", &(&1 <> "x")) == %{str: "x"}
    end

    test "preserves other keys" do
      result = map_update(%{a: 1, b: 2, c: 3}, :b, 0, &(&1 * 10))
      assert result == %{a: 1, b: 20, c: 3}
    end
  end

  describe "pad" do
    test "pads short lists" do
      assert pad([1, 2, 3], 5, nil) == [1, 2, 3, nil, nil]
      assert pad([1, 2, 3], 4, nil) == [1, 2, 3, nil]
      assert pad([], 3, nil) == [nil, nil, nil]
    end

    test "truncates long lists" do
      assert pad([1, 2, 3], 2, nil) == [1, 2]
      assert pad([1, 2, 3], 1, nil) == [1]
      assert pad([1, 2, 3], 0, nil) == []
    end

    test "preserves exact-length lists" do
      assert pad([1, 2, 3], 3, nil) == [1, 2, 3]
      assert pad([], 0, nil) == []
    end

    test "uses custom pad value" do
      assert pad([1], 3, 0) == [1, 0, 0]
      assert pad([1], 3, "x") == [1, "x", "x"]
    end
  end

  describe "zip_map" do
    test "equal length lists" do
      assert zip_map([1, 2, 3], [4, 5, 6], &{&1, &2}) == [{1, 4}, {2, 5}, {3, 6}]
    end

    test "first list shorter" do
      assert zip_map([1, 2], [4, 5, 6], &{&1, &2}) == [{1, 4}, {2, 5}, {nil, 6}]
      assert zip_map([1], [4, 5, 6], &{&1, &2}) == [{1, 4}, {nil, 5}, {nil, 6}]
    end

    test "second list shorter" do
      assert zip_map([1, 2, 3], [4, 5], &{&1, &2}) == [{1, 4}, {2, 5}, {3, nil}]
      assert zip_map([1, 2, 3], [4], &{&1, &2}) == [{1, 4}, {2, nil}, {3, nil}]
    end

    test "empty lists" do
      assert zip_map([], [], &{&1, &2}) == []
      assert zip_map([1, 2], [], &{&1, &2}) == [{1, nil}, {2, nil}]
      assert zip_map([], [1, 2], &{&1, &2}) == [{nil, 1}, {nil, 2}]
    end

    test "applies function to pairs" do
      assert zip_map([1, 2, 3], [10, 20, 30], &(&1 + &2)) == [11, 22, 33]
    end
  end

  describe "flatten" do
    test "scalars" do
      assert flatten(nil) == [{[[]], nil}]
      assert flatten(true) == [{[[]], true}]
      assert flatten(false) == [{[[]], false}]
      assert flatten(42) == [{[[]], 42}]
      assert flatten(3.14) == [{[[]], 3.14}]
      assert flatten("hello") == [{[[]], "hello"}]
    end

    test "nested lists of scalars" do
      assert flatten([1]) == [{[[]], [1]}]
      assert flatten([[1]]) == [{[[]], [[1]]}]
      assert flatten([[[1]]]) == [{[[]], [[[1]]]}]
    end

    test "simple maps" do
      assert flatten(%{"a" => 1}) == [{[["a"]], 1}]

      assert flatten(%{"a" => 1, "b" => 2}) |> Enum.sort() == [
               {[["a"]], 1},
               {[["b"]], 2},
             ]
    end

    test "nested maps" do
      assert flatten(%{"a" => %{"b" => 1}}) == [{[["a", "b"]], 1}]
      assert flatten(%{"a" => %{"b" => %{"c" => 1}}}) == [{[["a", "b", "c"]], 1}]
    end

    test "lists of maps" do
      assert flatten([%{"a" => 1}]) == [{[[], ["a"]], [1]}]
      assert flatten([%{"a" => 1}, %{"a" => 2}]) == [{[[], ["a"]], [1, 2]}]
    end

    test "maps containing lists of maps" do
      assert flatten(%{"a" => [%{"b" => 1}]}) == [{[["a"], ["b"]], [1]}]
      assert flatten(%{"a" => [%{"b" => 1}, %{"b" => 2}]}) == [{[["a"], ["b"]], [1, 2]}]
    end

    test "nested lists of maps" do
      result =
        flatten([
          %{"a" => [%{"b" => 1}, %{"b" => 2}]},
          %{"a" => [%{"b" => 3}]},
        ])

      assert result == [{[[], ["a"], ["b"]], [[1, 2], [3]]}]
    end

    test "sparse fields in list of maps" do
      result = flatten([%{"a" => 1, "b" => 2}, %{"a" => 3}])

      assert Enum.sort(result) == [
               {[[], ["a"]], [1, 3]},
               {[[], ["b"]], [2]},
             ]
    end

    test "empty structures" do
      assert flatten(%{}) == []
      assert flatten([]) == []
      assert flatten([%{}]) == []
      assert flatten([%{}, %{}]) == []
    end

    test "sparse fields are padded with nils up to the last item that has them" do
      result = flatten([%{"a" => 1}, %{"b" => 2}, %{}, %{"b" => 4}, %{"c" => 5}, %{}])

      assert Enum.sort(result) == [
               {[[], ["a"]], [1]},
               {[[], ["b"]], [nil, 2, nil, 4]},
               {[[], ["c"]], [nil, nil, nil, nil, 5]},
             ]
    end

    test "matches the original quadratic implementation" do
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..500 do
        value = equivalence_value(3)
        assert Enum.sort(flatten(value)) == Enum.sort(reference_flatten(value)), inspect(value)
      end
    end

    test "long lists flatten in linear time" do
      # The original implementation took minutes for lists this long.
      list = Enum.map(1..300_000, fn i -> %{"id" => i, "tags" => [i]} end)
      result = Enum.sort(flatten(%{"items" => list}))

      assert [{[["items"], ["id"]], ids}, {[["items"], ["tags"]], tags}] = result
      assert ids == Enum.to_list(1..300_000)
      assert length(tags) == 300_000

      assert flatten(List.duplicate(1, 1_000_000)) == [{[[]], List.duplicate(1, 1_000_000)}]
    end

    defp equivalence_value(0), do: Enum.random([nil, 1, "s", true])

    defp equivalence_value(depth) do
      case :rand.uniform(4) do
        1 ->
          equivalence_value(0)

        2 ->
          Enum.map(1..:rand.uniform(4), fn _ -> equivalence_value(depth - 1) end)

        3 ->
          Enum.map(1..:rand.uniform(4), fn _ ->
            Map.new(Enum.take_random(["a", "b", "c"], :rand.uniform(3)), fn key ->
              {key, equivalence_value(depth - 1)}
            end)
          end)

        4 ->
          Map.new(Enum.take_random(["a", "b", "c"], :rand.uniform(3)), fn key ->
            {key, equivalence_value(depth - 1)}
          end)
      end
    end

    # The implementation before linear-list-flattening, kept to check equivalence.
    defp reference_flatten(map) when is_map(map) do
      Enum.flat_map(map, fn {key, value} ->
        reference_flatten(value)
        |> Enum.map(fn {[init | rest], val} -> {[[key | init] | rest], val} end)
      end)
    end

    defp reference_flatten(list) when is_list(list) do
      list
      |> Enum.map(&reference_flatten/1)
      |> Enum.reduce({%{}, 0}, fn item_pairs, {map, count} ->
        map =
          Enum.reduce(item_pairs, map, fn {path, value}, map ->
            map_update(map, path, [], fn values -> pad(values, count, nil) ++ [value] end)
          end)

        {map, count + 1}
      end)
      |> elem(0)
      |> Enum.map(fn
        {[[]], values} -> {[[]], values}
        {path, values} -> {[[] | path], values}
      end)
    end

    defp reference_flatten(scalar), do: [{[[]], scalar}]
  end

  describe "from_events" do
    test "empty events" do
      assert_columns([], %{})
      assert_columns([%{}], %{})
      assert_columns([%{}, %{}, %{}], %{})
    end

    test "scalar value types" do
      assert_columns([%{"x" => nil}], %{[["x"]] => [nil]})
      assert_columns([%{"x" => true}], %{[["x"]] => [true]})
      assert_columns([%{"x" => false}], %{[["x"]] => [false]})
      assert_columns([%{"x" => 42}], %{[["x"]] => [42]})
      assert_columns([%{"x" => 3.14}], %{[["x"]] => [3.14]})
      assert_columns([%{"x" => "hello"}], %{[["x"]] => ["hello"]})
    end

    test "multiple fields" do
      assert_columns(
        [%{"a" => 1, "b" => 2}],
        %{[["a"]] => [1], [["b"]] => [2]}
      )
    end

    test "multiple events" do
      assert_columns(
        [%{"x" => 1}, %{"x" => 2}, %{"x" => 3}],
        %{[["x"]] => [1, 2, 3]}
      )
    end

    test "lists as scalar values" do
      assert_columns(
        [%{"tags" => ["a", "b"]}],
        %{[["tags"]] => [["a", "b"]]}
      )

      assert_columns(
        [%{"tags" => ["a"]}, %{"tags" => ["b", "c"]}],
        %{[["tags"]] => [["a"], ["b", "c"]]}
      )
    end

    test "mixed list nesting as scalar values" do
      assert_columns(
        [%{"x" => 1}, %{"x" => [2]}, %{"x" => [[3]]}],
        %{[["x"]] => [1, [2], [[3]]]}
      )
    end

    test "nested objects - one level" do
      assert_columns(
        [%{"a" => %{"b" => 1}}],
        %{[["a", "b"]] => [1]}
      )
    end

    test "nested objects - deep" do
      assert_columns(
        [%{"a" => %{"b" => %{"c" => 1}}}],
        %{[["a", "b", "c"]] => [1]}
      )
    end

    test "nested objects - multiple fields at different levels" do
      assert_columns(
        [%{"a" => %{"b" => 1, "c" => %{"d" => 2}}}],
        %{
          [["a", "b"]] => [1],
          [["a", "c", "d"]] => [2],
        }
      )
    end

    test "list of objects - one field" do
      assert_columns(
        [%{"a" => [%{"b" => 1}, %{"b" => 2}]}],
        %{[["a"], ["b"]] => [[1, 2]]}
      )
    end

    test "list of objects - multiple fields" do
      assert_columns(
        [%{"a" => [%{"b" => 1, "c" => 2}, %{"b" => 3, "c" => 4}]}],
        %{
          [["a"], ["b"]] => [[1, 3]],
          [["a"], ["c"]] => [[2, 4]],
        }
      )
    end

    test "list of objects - multiple events" do
      assert_columns(
        [
          %{"a" => [%{"b" => 1}]},
          %{"a" => [%{"b" => 2}, %{"b" => 3}]},
        ],
        %{[["a"], ["b"]] => [[1], [2, 3]]}
      )
    end

    test "list of objects - sparse fields" do
      assert_columns(
        [%{"a" => [%{"b" => 1, "c" => 2}, %{"b" => 3}]}],
        %{
          [["a"], ["b"]] => [[1, 3]],
          [["a"], ["c"]] => [[2]],
        }
      )
    end

    test "nested lists of objects" do
      assert_columns(
        [
          %{
            "a" => [
              %{"b" => [%{"c" => 1}, %{"c" => 2}]},
              %{"b" => [%{"c" => 3}]},
            ],
          },
        ],
        %{[["a"], ["b"], ["c"]] => [[[1, 2], [3]]]}
      )
    end

    test "sparse fields across events" do
      assert_columns(
        [
          %{"a" => 1, "b" => 2},
          %{"b" => 3, "c" => 4},
          %{"c" => 5, "a" => 6},
        ],
        %{
          [["a"]] => [1, 6],
          [["b"]] => [2, 3],
          [["c"]] => [4, 5],
        }
      )
    end

    test "empty list produces no columns" do
      assert_columns([%{"tags" => []}], %{})
    end
  end

  describe "to_events (round-trip)" do
    test "empty" do
      assert_round_trip([])
      assert_round_trip([%{}])
      assert_round_trip([%{}, %{}, %{}])
    end

    test "scalar fields" do
      assert_round_trip([%{"a" => 1}])
      assert_round_trip([%{"a" => 1, "b" => 2}])
      assert_round_trip([%{"a" => 1, "b" => 2}, %{"a" => 3, "b" => 4}])
    end

    test "various value types" do
      assert_round_trip([
        %{
          "a" => nil,
          "b" => true,
          "c" => 42,
          "d" => 3.14,
          "e" => "hello",
          "f" => [1, 2],
        },
      ])
    end

    test "mixed list nesting" do
      assert_round_trip([%{"a" => 1}, %{"a" => [2]}, %{"a" => [[3]]}])
    end

    test "nested objects" do
      assert_round_trip([%{"a" => 1}])
      assert_round_trip([%{"a" => [1]}])
      assert_round_trip([%{"a" => [[1]]}])

      assert_round_trip([%{"a" => %{"b" => 1}}])
      assert_round_trip([%{"a" => [%{"b" => 1}]}])
      assert_round_trip([%{"a" => [[%{"b" => 1}]]}])
      assert_round_trip([%{"a" => %{"b" => [1]}}])
      assert_round_trip([%{"a" => %{"b" => [[1]]}}])

      assert_round_trip([%{"a" => %{"b" => %{"c" => 1}}}])
      assert_round_trip([%{"a" => [%{"b" => %{"c" => 1}}]}])
      assert_round_trip([%{"a" => [[%{"b" => %{"c" => 1}}]]}])
      assert_round_trip([%{"a" => %{"b" => [%{"c" => 1}]}}])
      assert_round_trip([%{"a" => %{"b" => [[%{"c" => 1}]]}}])
      assert_round_trip([%{"a" => %{"b" => %{"c" => [1]}}}])
      assert_round_trip([%{"a" => %{"b" => %{"c" => [[1]]}}}])
    end

    test "lists of scalars" do
      assert_round_trip([%{"a" => [1, 2, 3]}])
      assert_round_trip([%{"a" => [1, 2]}, %{"a" => [3]}])
    end

    test "lists of objects" do
      assert_round_trip([%{"a" => [%{"b" => 1}, %{"b" => 2}]}])
      assert_round_trip([%{"a" => [%{"b" => 1, "c" => 2}, %{"b" => 3, "c" => 4}]}])

      assert_round_trip([
        %{"a" => [%{"b" => 1}]},
        %{"a" => [%{"b" => 2}, %{"b" => 3}]},
      ])
    end

    test "nested lists of objects" do
      assert_round_trip([
        %{
          "a" => [
            %{"b" => [%{"c" => 1}, %{"c" => 2}]},
            %{"b" => [%{"c" => 3}]},
          ],
        },
      ])
    end

    test "doubly nested lists of scalars" do
      assert_round_trip([%{"a" => [[1, 2], [3, 4]]}])
    end

    test "list of lists of objects" do
      assert_round_trip([%{"a" => [[%{"b" => 1}]]}])
    end

    test "multiple events with doubly nested lists" do
      assert_round_trip([
        %{"a" => [[1, 2], [3]]},
        %{"a" => [[4]]},
      ])
    end

    test "nested list inside nested list of objects" do
      assert_round_trip([
        %{"a" => [%{"b" => [[1, 2], [3]]}]},
      ])
    end
  end

  describe "encode_path" do
    test "simple keys" do
      assert encode_path([["a"]]) == "a"
      assert encode_path([["a", "b"]]) == "a.b"
      assert encode_path([["a", "b", "c"]]) == "a.b.c"
    end

    test "array traversal" do
      assert encode_path([["a"], ["b"]]) == "a..b"
      assert encode_path([["a", "b"], ["c"]]) == "a.b..c"
      assert encode_path([["a"], ["b"], ["c"]]) == "a..b..c"
    end

    test "nested arrays" do
      assert encode_path([["a"], [], ["b"]]) == "a...b"
      assert encode_path([["a"], [], [], ["b"]]) == "a....b"
    end

    test "keys with dots are quoted" do
      assert encode_path([["a.b"]]) == "\"a.b\""
      assert encode_path([["a", "b.c"]]) == "a.\"b.c\""
      assert encode_path([["a.b"], ["c.d"]]) == "\"a.b\"..\"c.d\""
    end

    test "keys with quotes are escaped" do
      assert encode_path([["a\"b"]]) == "\"a\\\"b\""
    end

    test "empty string keys are quoted" do
      assert encode_path([[""]]) == "\"\""
      assert encode_path([["a", ""]]) == "a.\"\""
    end
  end

  describe "decode_path" do
    test "simple keys" do
      assert decode_path("a") == [["a"]]
      assert decode_path("a.b") == [["a", "b"]]
      assert decode_path("a.b.c") == [["a", "b", "c"]]
    end

    test "array traversal" do
      assert decode_path("a..b") == [["a"], ["b"]]
      assert decode_path("a.b..c") == [["a", "b"], ["c"]]
      assert decode_path("a..b..c") == [["a"], ["b"], ["c"]]
    end

    test "nested arrays" do
      assert decode_path("a...b") == [["a"], [], ["b"]]
      assert decode_path("a....b") == [["a"], [], [], ["b"]]
    end

    test "quoted keys with dots" do
      assert decode_path("\"a.b\"") == [["a.b"]]
      assert decode_path("a.\"b.c\"") == [["a", "b.c"]]
      assert decode_path("\"a.b\"..\"c.d\"") == [["a.b"], ["c.d"]]
    end

    test "escaped quotes in keys" do
      assert decode_path("\"a\\\"b\"") == [["a\"b"]]
    end

    test "empty string keys" do
      assert decode_path("\"\"") == [[""]]
      assert decode_path("a.\"\"") == [["a", ""]]
    end

    test "round-trip encode/decode" do
      paths = [
        [["a"]],
        [["a", "b"]],
        [["a"], ["b"]],
        [["a", "b"], ["c", "d"]],
        [["a"], [], ["b"]],
        [["a"], [], [], ["b"]],
        [["a.b"]],
        [["a\"b"]],
        [[""]],
        [["a", "b.c", "d"]],
        [["x"], ["y.z"], ["w"]],
      ]

      for path <- paths do
        assert path |> encode_path() |> decode_path() == path,
               "Failed round-trip for #{inspect(path)}"
      end
    end
  end

  describe "flatten_event/unflatten_event" do
    test "simple scalar fields" do
      assert_flatten_event(%{"a" => 1}, %{"a" => 1})
      assert_flatten_event(%{"a" => 1, "b" => 2}, %{"a" => 1, "b" => 2})
    end

    test "nested objects" do
      assert_flatten_event(%{"a" => %{"b" => 1}}, %{"a.b" => 1})
      assert_flatten_event(%{"a" => %{"b" => %{"c" => 1}}}, %{"a.b.c" => 1})
    end

    test "lists of objects" do
      assert_flatten_event(
        %{"a" => [%{"b" => 1}, %{"b" => 2}]},
        %{"a..b" => [1, 2]}
      )
    end

    test "nested lists of objects" do
      assert_flatten_event(
        %{
          "a" => [
            %{"b" => [%{"c" => 1}, %{"c" => 2}]},
            %{"b" => [%{"c" => 3}]},
          ],
        },
        %{"a..b..c" => [[1, 2], [3]]}
      )
    end

    test "keys with dots are quoted" do
      assert_flatten_event(%{"a.b" => 1}, %{"\"a.b\"" => 1})
    end

    test "empty structures" do
      assert_flatten_event(%{}, %{})
    end

    test "multiple fields at different levels" do
      assert_flatten_event(
        %{"user" => %{"name" => "alice", "age" => 30}},
        %{"user.name" => "alice", "user.age" => 30}
      )
    end

    test "lists of objects with multiple fields" do
      assert_flatten_event(
        %{"items" => [%{"id" => 1, "name" => "a"}, %{"id" => 2, "name" => "b"}]},
        %{"items..id" => [1, 2], "items..name" => ["a", "b"]}
      )
    end

    test "deeply nested structure" do
      assert_flatten_event(
        %{"a" => %{"b" => [%{"c" => %{"d" => 1}}, %{"c" => %{"d" => 2}}]}},
        %{"a.b..c.d" => [1, 2]}
      )
    end

    test "nested keys with special characters" do
      assert_flatten_event(
        %{"a.b" => 1, "c" => %{"d.e" => 2}},
        %{"\"a.b\"" => 1, "c.\"d.e\"" => 2}
      )
    end
  end

  describe "random round-trip" do
    # Generate a random scalar value
    defp random_scalar do
      case :rand.uniform(5) do
        1 -> nil
        2 -> :rand.uniform(2) == 1
        3 -> :rand.uniform(1000) - 500
        4 -> :rand.uniform() * 1000 - 500
        5 -> random_string(0..10)
      end
    end

    # Generate a random alphanumeric string
    defp random_string(length_range) do
      length = Enum.random(length_range)

      if length == 0 do
        ""
      else
        chars = ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

        for _ <- 1..length, into: "" do
          <<Enum.random(chars)>>
        end
      end
    end

    # Generate a non-nil scalar value
    defp random_non_nil_scalar do
      case :rand.uniform(4) do
        1 -> :rand.uniform(2) == 1
        2 -> :rand.uniform(1000) - 500
        3 -> :rand.uniform() * 1000 - 500
        4 -> random_string(0..10)
      end
    end

    # Generate a list of scalars (no nils - they don't roundtrip in lists)
    defp random_scalar_list do
      for _ <- 1..:rand.uniform(5), do: random_non_nil_scalar()
    end

    # Generate nested lists of scalars (no nils in lists)
    defp random_nested_scalar_list(depth) do
      if depth <= 0 do
        random_non_nil_scalar()
      else
        case :rand.uniform(2) do
          1 -> random_non_nil_scalar()
          2 -> for(_ <- 1..:rand.uniform(3), do: random_nested_scalar_list(depth - 1))
        end
      end
    end

    # Generate a random value for an event field
    # Only generates structures that VirtualSegment supports
    defp random_value(depth) do
      if depth <= 0 do
        case :rand.uniform(2) do
          1 -> random_scalar()
          2 -> random_scalar_list()
        end
      else
        case :rand.uniform(5) do
          1 -> random_scalar()
          2 -> random_scalar_list()
          3 -> random_nested_scalar_list(2)
          # Nested map (only scalar/list values, no further nesting)
          4 -> random_flat_event()
          # List of flat objects with same keys
          5 -> random_flat_event_list()
        end
      end
    end

    # Generate a flat event (only scalar values, no nested maps or lists of maps)
    defp random_flat_event do
      num_fields = :rand.uniform(4)

      for _ <- 1..num_fields, into: %{} do
        key = random_string(1..5)
        value = random_flat_value()
        {key, value}
      end
    end

    # Generate a value for a flat event field (scalars can be nil, but list elements cannot)
    defp random_flat_value do
      case :rand.uniform(3) do
        1 -> random_scalar()
        2 -> random_scalar_list()
        3 -> random_nested_scalar_list(2)
      end
    end

    # Generate a list of flat events with the same keys
    defp random_flat_event_list do
      num_fields = :rand.uniform(4)
      keys = for _ <- 1..num_fields, do: random_string(1..5)
      num_items = :rand.uniform(3)

      for _ <- 1..num_items do
        Map.new(keys, fn key -> {key, random_flat_value()} end)
      end
    end

    # Generate a random event with potentially nested structure
    defp random_event(depth) do
      num_fields = :rand.uniform(4)

      for _ <- 1..num_fields, into: %{} do
        key = random_string(1..5)
        value = random_value(depth)
        {key, value}
      end
    end

    # Generate a value generator spec (defines structure but not actual values)
    defp random_value_spec do
      case :rand.uniform(5) do
        1 ->
          :scalar

        2 ->
          :scalar_list

        3 ->
          :nested_scalar_list

        4 ->
          # Nested map with fixed keys
          num_fields = :rand.uniform(4)
          nested_keys = for _ <- 1..num_fields, do: random_string(1..5)
          {:flat_event, nested_keys}

        5 ->
          # List of maps with fixed keys
          num_fields = :rand.uniform(4)
          nested_keys = for _ <- 1..num_fields, do: random_string(1..5)
          {:flat_event_list, nested_keys}
      end
    end

    # Generate a value from a spec
    defp random_value_from_spec(:scalar), do: random_scalar()
    defp random_value_from_spec(:scalar_list), do: random_scalar_list()
    defp random_value_from_spec(:nested_scalar_list), do: random_nested_scalar_list(2)

    defp random_value_from_spec({:flat_event, keys}) do
      Map.new(keys, fn key -> {key, random_flat_value()} end)
    end

    defp random_value_from_spec({:flat_event_list, keys}) do
      num_items = :rand.uniform(3)

      for _ <- 1..num_items do
        Map.new(keys, fn key -> {key, random_flat_value()} end)
      end
    end

    # Generate multiple events with consistent structure (same keys and value types)
    defp random_events_consistent do
      num_keys = :rand.uniform(4)
      keys = for _ <- 1..num_keys, do: random_string(1..5)
      num_events = :rand.uniform(5)

      # Decide the value spec for each key once, then use same structure for all events
      key_specs = Map.new(keys, fn key -> {key, random_value_spec()} end)

      for _ <- 1..num_events do
        Map.new(keys, fn key ->
          {key, random_value_from_spec(key_specs[key])}
        end)
      end
    end

    test "randomly generated events round-trip correctly" do
      for _ <- 1..100 do
        events = random_events_consistent()
        result = events |> from_events() |> to_events()
        assert result == events, "Failed to round-trip: #{inspect(events)}"
      end
    end

    test "single random event round-trips correctly" do
      for _ <- 1..100 do
        event = random_event(3)
        events = [event]
        result = events |> from_events() |> to_events()
        assert result == events, "Failed to round-trip: #{inspect(events)}"
      end
    end

    test "multiple events with same keys round-trip correctly" do
      for _ <- 1..100 do
        num_keys = :rand.uniform(4)
        keys = for _ <- 1..num_keys, do: random_string(1..5)
        num_events = :rand.uniform(5)

        events =
          for _ <- 1..num_events do
            Map.new(keys, fn key ->
              value = Enum.random([nil, true, false, :rand.uniform(100), "test"])
              {key, value}
            end)
          end

        result = events |> from_events() |> to_events()
        assert result == events, "Failed to round-trip: #{inspect(events)}"
      end
    end
  end
end

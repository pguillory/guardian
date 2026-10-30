defmodule Guardian.Storage.FlatteningTest do
  use ExUnit.Case
  import Guardian.Storage.Flattening

  defp assert_flatten_event(event, expected) do
    assert flatten_event(event) == expected
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

    defp equivalence_value(0) do
      Enum.random([nil, 1, "s", true])
    end

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
            Map.update(map, path, pad([], count, nil) ++ [value], fn values ->
              pad(values, count, nil) ++ [value]
            end)
          end)

        {map, count + 1}
      end)
      |> elem(0)
      |> Enum.map(fn
        {[[]], values} -> {[[]], values}
        {path, values} -> {[[] | path], values}
      end)
    end

    defp reference_flatten(scalar) do
      [{[[]], scalar}]
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

    test "backslashes in quoted keys are escaped" do
      assert encode_path([["a.\\"]]) == "\"a.\\\\\""
      assert encode_path([["a\\\"b"]]) == "\"a\\\\\\\"b\""
      # A key that needs no quotes keeps its backslashes as they are.
      assert encode_path([["a\\b"]]) == "a\\b"
    end

    test "empty string keys are quoted" do
      assert encode_path([[""]]) == "\"\""
      assert encode_path([["a", ""]]) == "a.\"\""
    end
  end

  describe "flatten_event" do
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
end

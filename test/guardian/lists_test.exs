defmodule Guardian.ListsTest do
  use ExUnit.Case, async: true
  alias Guardian.Lists

  test "unflatten restores the nesting, including empty lists" do
    nested = [[], [:a, :b], [], [:c], []]
    assert Lists.flatten(nested) == [:a, :b, :c]
    assert Lists.unflatten([1, 2, 3], nested) == [[], [1, 2], [], [3], []]
    assert Lists.unflatten([], []) == []
    assert Lists.unflatten([], [[], []]) == [[], []]
    assert_raise FunctionClauseError, fn -> Lists.unflatten([1, 2], nested) end
    assert_raise MatchError, fn -> Lists.unflatten([1, 2, 3, 4], nested) end
  end

  test "unfilter puts replacements back in place of matching items" do
    list = [1, :x, 2, :y, 3]
    assert Lists.filter(list, &is_atom/1) == [:x, :y]
    assert Lists.unfilter([:a, :b], list, &is_atom/1) == [1, :a, 2, :b, 3]
    assert Lists.unfilter([], [1, 2], &is_atom/1) == [1, 2]
    assert Lists.unfilter([:a, :b], [:x, :y], &is_atom/1) == [:a, :b]
    assert Lists.unfilter([], [], &is_atom/1) == []
    assert_raise MatchError, fn -> Lists.unfilter([:a], list, &is_atom/1) end
    assert_raise FunctionClauseError, fn -> Lists.unfilter([:a, :b, :c], list, &is_atom/1) end
  end

  test "group sorts keys and keeps each key's order; ungroup restores interleaving" do
    pairs = [{:b, 1}, {:a, 2}, {:b, 3}, {:c, 4}, {:a, 5}, {:b, 6}]
    groups = Lists.group(pairs)
    assert groups == [{:a, [2, 5]}, {:b, [1, 3, 6]}, {:c, [4]}]
    keys = Enum.map(pairs, &elem(&1, 0))
    assert Lists.ungroup(groups, keys) == [1, 2, 3, 4, 5, 6]
    assert Lists.group([]) == []
    assert Lists.ungroup([], []) == []

    assert_raise MatchError, fn ->
      Lists.ungroup([{:a, [2]}, {:b, [1, 3, 6]}, {:c, [4]}], keys)
    end

    assert_raise KeyError, fn -> Lists.ungroup([{:a, [2, 5]}, {:b, [1, 3, 6]}], keys) end

    assert_raise MatchError, fn ->
      Lists.ungroup([{:a, [2, 5, 7]}, {:b, [1, 3, 6]}, {:c, [4]}], keys)
    end
  end
end

defmodule Guardian.ListsTest do
  use ExUnit.Case, async: true
  import Guardian.Lists

  test "unflatten restores the nesting, including empty lists" do
    nested = [[], [:a, :b], [], [:c], []]
    assert flatten(nested) == [:a, :b, :c]
    assert unflatten([1, 2, 3], nested) == [[], [1, 2], [], [3], []]
    assert unflatten([], []) == []
    assert unflatten([], [[], []]) == [[], []]
    assert_raise FunctionClauseError, fn -> unflatten([1, 2], nested) end
    assert_raise MatchError, fn -> unflatten([1, 2, 3, 4], nested) end
  end

  test "unflatten is the inverse of flatten at any depth" do
    nested = [:a, [], [:b, [:c, [[]], :d]], [[[:e]]], :f]
    assert flatten(nested) == [:a, :b, :c, :d, :e, :f]
    assert unflatten(flatten(nested), nested) == nested
    assert unflatten([1, 2, 3, 4, 5, 6], nested) == [1, [], [2, [3, [[]], 4]], [[[5]]], 6]
    assert unflatten([], [[[]], []]) == [[[]], []]
    assert unflatten([1, 2], [{:not, :nesting}, [%{not: :nesting}]]) == [1, [2]]
    assert_raise FunctionClauseError, fn -> unflatten([1, 2], nested) end
    assert_raise MatchError, fn -> unflatten([1, 2, 3, 4, 5, 6, 7], nested) end
  end

  test "unfilter puts replacements back in place of matching items" do
    list = [1, :x, 2, :y, 3]
    assert filter(list, &is_atom/1) == [:x, :y]
    assert unfilter([:a, :b], list, &is_atom/1) == [1, :a, 2, :b, 3]
    assert unfilter([], [1, 2], &is_atom/1) == [1, 2]
    assert unfilter([:a, :b], [:x, :y], &is_atom/1) == [:a, :b]
    assert unfilter([], [], &is_atom/1) == []
    assert_raise MatchError, fn -> unfilter([:a], list, &is_atom/1) end
    assert_raise FunctionClauseError, fn -> unfilter([:a, :b, :c], list, &is_atom/1) end
  end

  test "group sorts keys and keeps each key's order; ungroup restores interleaving" do
    pairs = [{:b, 1}, {:a, 2}, {:b, 3}, {:c, 4}, {:a, 5}, {:b, 6}]
    groups = group(pairs)
    assert groups == [{:a, [2, 5]}, {:b, [1, 3, 6]}, {:c, [4]}]
    keys = Enum.map(pairs, &elem(&1, 0))
    assert ungroup(groups, keys) == [1, 2, 3, 4, 5, 6]
    assert group([]) == []
    assert ungroup([], []) == []

    assert_raise MatchError, fn ->
      ungroup([{:a, [2]}, {:b, [1, 3, 6]}, {:c, [4]}], keys)
    end

    assert_raise KeyError, fn -> ungroup([{:a, [2, 5]}, {:b, [1, 3, 6]}], keys) end

    assert_raise MatchError, fn ->
      ungroup([{:a, [2, 5, 7]}, {:b, [1, 3, 6]}, {:c, [4]}], keys)
    end
  end

  test "merge_take" do
    asc = &(&1 <= &2)
    assert merge_take([1, 2], [3, 4], 5, asc) == [1, 2, 3, 4]
    assert merge_take([1, 2], [3, 4], 4, asc) == [1, 2, 3, 4]
    assert merge_take([1, 3], [2, 4], 3, asc) == [1, 2, 3]
    assert merge_take([3, 4], [1, 2], 2, asc) == [1, 2]
    assert merge_take([1, 2], [3, 4], 1, asc) == [1]
    assert merge_take([1, 2], [3, 4], 0, asc) == []
    assert merge_take([], [3, 4], 1, asc) == [3]
  end

  test "merge_take breaks ties by first?" do
    assert merge_take([1], [1.0], 2, &(&1 <= &2)) === [1, 1.0]
    assert merge_take([1], [1.0], 2, &(&1 < &2)) === [1.0, 1]
  end
end

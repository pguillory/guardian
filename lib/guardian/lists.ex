defmodule Guardian.Lists do
  @moduledoc """
  Generic list helpers that keep items in order.

  Reshaping and back: each inverse walks its shape once, taking heads, with no
  positional ids or index lookups, and raises when its inputs do not fit the shape.

  - `flatten/1` and `unflatten/2`: flatten nested lists at any depth, then rebuild that
    nesting from a flat list of the same total length. Any list in the shape is nesting,
    so an item that is itself a list does not survive the round trip.
  - `filter/2` and `unfilter/3`: keep the matching items, then put replacements back
    in place of the items that matched.
  - `group/1` and `ungroup/2`: gather `{key, value}` pairs into `[{key, values}]`
    with keys sorted and values in input order, then walk a key sequence taking the
    head of each key's values.

  Merging: `merge_take/4` merges two lists already in order and keeps the first `n`.
  """

  @doc "Flattens nested lists at any depth, like `List.flatten/1`."
  def flatten(lists) do
    List.flatten(lists)
  end

  @doc """
  The inverse of `flatten/1`: rebuilds the nesting of `shape`, at any depth, with the
  items of `flat` in order. Raises when `flat` has too few or too many items.
  """
  def unflatten(flat, shape) do
    {result, []} = take_like(shape, flat)
    result
  end

  defp take_like([], rest) do
    {[], rest}
  end

  defp take_like([head | tail], rest) when is_list(head) do
    {head, rest} = take_like(head, rest)
    {tail, rest} = take_like(tail, rest)
    {[head | tail], rest}
  end

  defp take_like([_ | tail], [item | rest]) do
    {tail, rest} = take_like(tail, rest)
    {[item | tail], rest}
  end

  @doc "The items for which `fun` returns true, in order."
  def filter(list, fun) do
    Enum.filter(list, fun)
  end

  @doc """
  `list` with each item for which `fun` returns true replaced, in order, by the
  next item of `replacements`.
  """
  def unfilter(replacements, list, fun) do
    unfilter(replacements, list, fun, [])
  end

  defp unfilter([], [], _fun, acc) do
    Enum.reverse(acc)
  end

  defp unfilter(replacements, [item | list], fun, acc) do
    if fun.(item) do
      [replacement | replacements] = replacements
      unfilter(replacements, list, fun, [replacement | acc])
    else
      unfilter(replacements, list, fun, [item | acc])
    end
  end

  @doc "Groups `{key, value}` pairs by key: keys sorted, each key's values in input order."
  def group(pairs) do
    pairs
    |> Enum.reduce(%{}, fn {key, value}, groups ->
      Map.update(groups, key, [value], &[value | &1])
    end)
    |> Enum.map(fn {key, values} -> {key, Enum.reverse(values)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  For each key in `keys`, the next value of that key's list in `groups`
  (`[{key, values}]`). Every value must be taken.
  """
  def ungroup(groups, keys) do
    {values, rest} =
      Enum.map_reduce(keys, Map.new(groups), fn key, groups ->
        [value | values] = Map.fetch!(groups, key)
        {value, Map.put(groups, key, values)}
      end)

    true = Enum.all?(rest, &match?({_, []}, &1))
    values
  end

  @doc """
  Merges two lists, each already in order, and keeps the first `n` elements.
  `first?.(a, b)` says whether `a` (from `list1`) goes before `b` (from `list2`); when
  it returns false, as on a tie under a strict comparison, `b` goes first.
  """
  def merge_take(_list1, _list2, 0, _first?) do
    []
  end

  def merge_take([a | rest1] = list1, [b | rest2] = list2, n, first?) when n > 0 do
    if first?.(a, b) do
      [a | merge_take(rest1, list2, n - 1, first?)]
    else
      [b | merge_take(list1, rest2, n - 1, first?)]
    end
  end

  def merge_take([], list2, n, _first?) do
    Enum.take(list2, n)
  end

  def merge_take(list1, [], n, _first?) do
    Enum.take(list1, n)
  end
end

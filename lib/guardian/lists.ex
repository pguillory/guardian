defmodule Guardian.Lists do
  @moduledoc """
  Generic list reshaping that keeps items in order: each inverse walks its shape
  once, taking heads, with no positional ids or index lookups.

  - `flatten/1` and `unflatten/2`: concatenate a list of lists, then rebuild that
    nesting from a flat list of the same total length.
  - `filter/2` and `unfilter/3`: keep the matching items, then put replacements back
    in place of the items that matched.
  - `group/1` and `ungroup/2`: gather `{key, value}` pairs into `[{key, values}]`
    with keys sorted and values in input order, then walk a key sequence taking the
    head of each key's values.

  Each inverse raises when its inputs do not fit the shape.
  """

  @doc "Concatenates a list of lists."
  def flatten(lists) do
    Enum.concat(lists)
  end

  @doc "Splits `flat` into lists of the same lengths as the lists in `shape`."
  def unflatten(flat, shape) do
    {lists, []} = Enum.map_reduce(shape, flat, &take_like/2)
    lists
  end

  defp take_like([], rest) do
    {[], rest}
  end

  defp take_like([_ | shape], [item | rest]) do
    {items, rest} = take_like(shape, rest)
    {[item | items], rest}
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
end

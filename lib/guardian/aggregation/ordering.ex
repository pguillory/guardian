defmodule Guardian.Aggregation.Ordering do
  @moduledoc """
  What the min and max aggregation families share. `extreme` is `:min` or `:max`.
  """

  @doc """
  Whether `key1` wins over `key2`: strictly less for `:min`, strictly greater for
  `:max`. A tie is false, so the second argument wins it.
  """
  def wins?(:min, key1, key2) do
    key1 < key2
  end

  def wins?(:max, key1, key2) do
    key1 > key2
  end

  @doc """
  Checks the `n` argument of a `_n` aggregation named `name`.
  """
  def check_n!(_name, n) when is_integer(n) and n >= 0 do
    n
  end

  def check_n!(name, _n) do
    raise Guardian.Query.Error, message: "#{name}: n must be a non-negative integer"
  end

  @doc """
  Merges two `{list, n}` accumulators of a `_n` aggregation named `name`, each list
  sorted best first, keeping the best `n`. `wins?` compares two list elements.
  `:empty`, the state of no rows, is an identity on either side.
  """
  def merge_n(_name, :empty, acc2, _wins?) do
    acc2
  end

  def merge_n(_name, acc1, :empty, _wins?) do
    acc1
  end

  def merge_n(_name, {list1, n}, {list2, n}, wins?) do
    {Guardian.Query.Sorting.merge_take(list1, list2, n, wins?), n}
  end

  def merge_n(name, _acc1, _acc2, _wins?) do
    raise Guardian.Query.Error, message: "#{name}: n must be the same for every row of a group"
  end
end

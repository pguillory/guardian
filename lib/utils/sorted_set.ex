defmodule SortedSet do
  def new do
    []
  end

  def new(enum) do
    enum
    |> Enum.uniq()
    |> Enum.sort()
  end

  def put(set, key) do
    union(set, [key])
  end

  def union([key | keys1], [key | keys2]) do
    [key | union(keys1, keys2)]
  end

  def union([key1 | keys1], [key2 | keys2]) when key1 < key2 do
    [key1 | union(keys1, [key2 | keys2])]
  end

  def union([key1 | keys1], [key2 | keys2]) when key1 > key2 do
    [key2 | union([key1 | keys1], keys2)]
  end

  def union([], keys2) do
    keys2
  end

  def union(keys1, []) do
    keys1
  end

  def diff([key | keys1], [key | keys2]) do
    diff(keys1, keys2)
  end

  def diff([key1 | keys1], [key2 | keys2]) when key1 < key2 do
    [key1 | diff(keys1, [key2 | keys2])]
  end

  def diff([key1 | keys1], [key2 | keys2]) when key1 > key2 do
    diff([key1 | keys1], keys2)
  end

  def diff(keys1, _keys2) do
    keys1
  end

  def intersect([key | keys1], [key | keys2]) do
    [key | intersect(keys1, keys2)]
  end

  def intersect([key1 | keys1], [key2 | keys2]) when key1 < key2 do
    intersect(keys1, [key2 | keys2])
  end

  def intersect([key1 | keys1], [key2 | keys2]) when key1 > key2 do
    intersect([key1 | keys1], keys2)
  end

  def intersect(_keys1, _keys2) do
    []
  end
end

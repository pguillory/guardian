defmodule Guardian.Query.Sorting do
  # Rows sort by their leading values, one direction (`:asc` or `:desc`) per value; the
  # rest of the row follows unchanged (`drop_prefix/2` removes the sort values).
  @min_chunk_rows 1024

  # Rows with equal keys keep their input order in both sorts: compare/3 answers
  # :row1 on a tie, and Enum.sort/2 is stable when the sorter returns true for equal
  # elements.
  def sort(rows, directions) do
    Enum.sort(rows, &(compare(&1, &2, directions) == :row1))
  end

  # The input is read to the end even when the limit is 0 (pipeline stages must read
  # all their input). Sorting it in chunks of max(limit, @min_chunk_rows) rows keeps
  # the work at O(n log chunk) and the rows held at a few chunks.
  def sort_limit(rows, _directions, 0) do
    Stream.run(rows)
    []
  end

  def sort_limit(rows, directions, limit) do
    rows
    |> Stream.chunk_every(max(limit, @min_chunk_rows))
    |> Enum.reduce([], fn chunk, top ->
      # The rows kept so far came first, so they go on the left to win ties.
      merge_take(top, sort(chunk, directions), limit, &(compare(&1, &2, directions) == :row1))
    end)
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

  defp compare([value1 | rest1], [value2 | rest2], [:asc | directions]) do
    cond do
      value1 < value2 -> :row1
      value1 > value2 -> :row2
      true -> compare(rest1, rest2, directions)
    end
  end

  defp compare([value1 | rest1], [value2 | rest2], [:desc | directions]) do
    cond do
      value1 < value2 -> :row2
      value1 > value2 -> :row1
      true -> compare(rest1, rest2, directions)
    end
  end

  defp compare(_row1, _row2, []) do
    :row1
  end

  def drop_prefix([row | rows], directions) do
    [drop_as_many(row, directions) | drop_prefix(rows, directions)]
  end

  def drop_prefix([], _directions) do
    []
  end

  defp drop_as_many([_ | row], [_ | directions]) do
    drop_as_many(row, directions)
  end

  defp drop_as_many(row, []) do
    row
  end
end

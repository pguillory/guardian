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
      Guardian.Lists.merge_take(
        top,
        sort(chunk, directions),
        limit,
        &(compare(&1, &2, directions) == :row1)
      )
    end)
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

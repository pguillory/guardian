defmodule Guardian.Query.SortingTest do
  import Guardian.Query.Sorting
  use ExUnit.Case, async: true

  # The reference order: each key ascending or descending, ties in input order.
  defp reference_sort(rows, directions) do
    directions
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce(rows, fn {direction, i}, rows ->
      Enum.sort_by(rows, &Enum.at(&1, i), direction)
    end)
  end

  defp random_rows(count) do
    for i <- 1..count, do: [:rand.uniform(10), :rand.uniform(1000), i]
  end

  test "sort" do
    assert sort([[2], [1], [3]], [:asc]) == [[1], [2], [3]]
    assert sort([[2], [1], [3]], [:desc]) == [[3], [2], [1]]
    assert sort([], [:asc]) == []

    rows = random_rows(5000)

    for directions <- [[:asc, :desc], [:desc, :asc]] do
      assert sort(rows, directions) == reference_sort(rows, directions)
    end
  end

  test "sort keeps ties in input order" do
    assert sort([[1, :a], [1, :b], [0, :c], [1, :d]], [:asc]) ==
             [[0, :c], [1, :a], [1, :b], [1, :d]]

    assert sort([[1, :a], [1, :b], [0, :c], [1, :d]], [:desc]) ==
             [[1, :a], [1, :b], [1, :d], [0, :c]]
  end

  test "sort_limit" do
    rows = random_rows(5000)

    for directions <- [[:asc, :desc], [:desc, :asc]],
        limit <- [0, 1, 10, 1023, 1024, 1025, 3000, 5000, 6000] do
      assert sort_limit(rows, directions, limit) ==
               rows |> reference_sort(directions) |> Enum.take(limit)
    end
  end

  test "sort_limit keeps ties in input order across chunks" do
    rows = for i <- 1..3000, do: [rem(i, 2), i]

    assert sort_limit(rows, [:asc], 2000) ==
             rows |> Enum.sort_by(&hd/1) |> Enum.take(2000)
  end

  test "sort_limit reads all its input when the limit is 0" do
    test_pid = self()

    rows =
      Stream.map(1..10, fn i ->
        send(test_pid, {:read, i})
        [i]
      end)

    assert sort_limit(rows, [:asc], 0) == []
    assert_received {:read, 10}
  end

  # The old insertion sorts took minutes here (O(n^2) and O(n * limit)), far past
  # ExUnit's 60-second test timeout and the 30-second query limit.
  test "sort and sort_limit handle the 100,000-row result cap" do
    rows = random_rows(100_000)
    sorted = reference_sort(rows, [:asc, :desc])
    assert sort(rows, [:asc, :desc]) == sorted
    assert sort_limit(rows, [:asc, :desc], 100_000) == sorted
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

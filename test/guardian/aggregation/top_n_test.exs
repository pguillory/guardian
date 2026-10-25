defmodule Guardian.Aggregation.TopNTest do
  # n handling and null skipping shared by min_n, max_n, min_n_by and max_n_by, and
  # null ordering keys in min_by and max_by.
  use Guardian.Query.EvaluationTestCase, async: true

  defp values(xs), do: Enum.map(xs, &[x: &1])

  test "n = 0 gives an empty list" do
    assert eval_aggregate("min_n(x, 0)", values([1, 2, 3])) == []
    assert eval_aggregate("min_n(x, 0)", values([1])) == []
    assert eval_aggregate("max_n(x, 0)", values([1, 2, 3])) == []
    assert eval_aggregate("min_n_by(x, x, 0)", values([1, 2, 3])) == []
    assert eval_aggregate("max_n_by(x, x, 0)", values([1])) == []
  end

  test "n larger than the group gives every value" do
    assert eval_aggregate("min_n(x, 5)", values([3, 1, 2])) == [1, 2, 3]
    assert eval_aggregate("max_n(x, 5)", values([3, 1, 2])) == [3, 2, 1]
  end

  test "n may be a constant expression" do
    assert eval_aggregate("min_n(x, 1 + 1)", values([3, 1, 2])) == [1, 2]
  end

  test "n must be a non-negative integer" do
    for source <- ["min_n(x, n)", "max_n(x, n)", "min_n_by(x, x, n)", "max_n_by(x, x, n)"],
        n <- [-1, 2.5, "a", nil, true] do
      name = source |> String.split("(") |> hd()

      assert_raise Guardian.Query.Error, "#{name}: n must be a non-negative integer", fn ->
        eval_aggregate(source, [[x: 1, n: n], [x: 2, n: n]])
      end
    end
  end

  test "n must be the same for every row of a group" do
    for source <- ["min_n(x, n)", "max_n(x, n)", "min_n_by(x, x, n)", "max_n_by(x, x, n)"] do
      name = source |> String.split("(") |> hd()

      assert_raise Guardian.Query.Error,
                   "#{name}: n must be the same for every row of a group",
                   fn ->
                     eval_aggregate(source, [[x: 1, n: 1], [x: 2, n: 2]])
                   end
    end
  end

  test "null values are skipped" do
    assert eval_aggregate("min_n(x, 5)", values([1, nil, 3])) == [1, 3]
    assert eval_aggregate("max_n(x, 2)", values([1, nil, 3])) == [3, 1]
    assert eval_aggregate("min_n(x, 2)", values([nil, nil])) == []
    assert eval_aggregate("max_n(x, 2)", values([nil])) == []
  end

  test "rows whose ordering key is null are skipped" do
    rows = [[x: "a", y: 1], [x: "b", y: nil], [x: "c", y: 2]]
    assert eval_aggregate("min_n_by(x, y, 3)", rows) == ["a", "c"]
    assert eval_aggregate("max_n_by(x, y, 3)", rows) == ["c", "a"]
    assert eval_aggregate("min_by(x, y)", rows) == "a"
    assert eval_aggregate("max_by(x, y)", rows) == "c"

    null_first = [[x: "a", y: nil], [x: "b", y: 1]]
    assert eval_aggregate("min_by(x, y)", null_first) == "b"
    assert eval_aggregate("max_by(x, y)", null_first) == "b"

    null_keys = [[x: "a", y: nil], [x: "b", y: nil]]
    assert eval_aggregate("min_n_by(x, y, 3)", null_keys) == []
    assert eval_aggregate("max_by(x, y)", null_keys) == nil
    assert eval_aggregate("min_by(x, y)", null_keys) == nil
  end

  test "a null value with a non-null ordering key is kept" do
    rows = [[x: nil, y: 1], [x: "b", y: 2]]
    assert eval_aggregate("min_by(x, y)", rows) == nil
    assert eval_aggregate("max_by(x, y)", rows) == "b"
    assert eval_aggregate("min_n_by(x, y, 2)", rows) == [nil, "b"]
  end
end

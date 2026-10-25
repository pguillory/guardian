defmodule Guardian.Aggregation.MinMaxFamilyTest do
  # Behavior shared by min and max and their _by, _n and _n_by forms: which of equal
  # keys wins, null skipping, and Erlang term order across types.
  use Guardian.Query.EvaluationTestCase, async: true

  defp values(xs) do
    Enum.map(xs, &[x: &1])
  end

  # 1 and 1.0 compare equal, so === shows which row won the tie: the earlier row.
  test "of equal keys, the earlier row wins" do
    assert eval_aggregate("min(x)", values([1, 1.0])) === 1
    assert eval_aggregate("max(x)", values([1, 1.0])) === 1
    assert eval_aggregate("min(x)", values([1.0, 1])) === 1.0

    ties = [[x: "a", y: 1], [x: "b", y: 1], [x: "c", y: 0], [x: "d", y: 2]]
    assert eval_aggregate("min_by(x, y)", ties) == "c"
    assert eval_aggregate("max_by(x, y)", ties) == "d"
    assert eval_aggregate("min_by(x, y)", Enum.take(ties, 2)) == "a"
    assert eval_aggregate("max_by(x, y)", Enum.take(ties, 2)) == "a"

    assert eval_aggregate("min_n(x, 2)", values([1, 1.0, 2])) === [1, 1.0]
    assert eval_aggregate("max_n(x, 2)", values([1.0, 0, 1])) === [1.0, 1]
    assert eval_aggregate("min_n_by(x, y, 3)", ties) == ["c", "a", "b"]
    assert eval_aggregate("max_n_by(x, y, 3)", ties) == ["d", "a", "b"]
    # Truncated at a tie: the earlier of the tied rows is kept.
    assert eval_aggregate("min_n_by(x, y, 2)", ties) == ["c", "a"]
    assert eval_aggregate("max_n_by(x, y, 2)", ties) == ["d", "a"]
  end

  test "min and max skip nulls on either side" do
    assert eval_aggregate("min(x)", values([nil, 3, nil, 2])) == 2
    assert eval_aggregate("max(x)", values([3, nil, 5, nil])) == 5
    assert eval_aggregate("min(x)", values([nil, nil])) == nil
    assert eval_aggregate("max(x)", values([nil])) == nil
  end

  test "values of different types compare in Erlang term order" do
    mixed = values([1, "a", true, [1], 2.5])
    assert eval_aggregate("min(x)", mixed) == 1
    assert eval_aggregate("max(x)", mixed) == "a"
    assert eval_aggregate("min_n(x, 3)", mixed) == [1, 2.5, true]
    assert eval_aggregate("max_n(x, 2)", mixed) == ["a", [1]]
  end

  test "no rows gives the default" do
    assert eval_aggregate("min(x)", []) == nil
    assert eval_aggregate("max_by(x, y)", []) == nil
    assert eval_aggregate("min_n(x, 2)", []) == nil
    assert eval_aggregate("max_n_by(x, y, 2)", []) == nil
    assert eval_aggregate("max_n(x, 0)", []) == nil
    assert eval_aggregate("min_n_by(x, y, 0)", []) == nil
  end

  test "stddev and variance are the sample forms" do
    rows = values([4, 7, 13, 16])
    assert eval_aggregate("stddev(x)", rows) === eval_aggregate("stddev_samp(x)", rows)
    assert eval_aggregate("variance(x)", rows) === eval_aggregate("var_samp(x)", rows)
    assert eval_aggregate("var_pop(x)", []) == nil
  end
end

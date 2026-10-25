defmodule Guardian.Aggregation.CountDistinctTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "count_distinct" do
    assert eval_aggregate("count_distinct(x)", []) == 0
    assert eval_aggregate("count_distinct(x)", [[x: 1], [x: 2], [x: 3]]) == 3
    assert eval_aggregate("count_distinct(x)", [[x: 1], [x: 1], [x: 1]]) == 1
    assert eval_aggregate("count_distinct(x)", [[x: 1], [x: 2], [x: 1], [x: 2]]) == 2
  end

  test "count_distinct with strings" do
    assert eval_aggregate("count_distinct(x)", [[x: "a"], [x: "b"], [x: "a"]]) == 2
  end

  # As COUNT(DISTINCT x) in standard SQL, and like count(x).
  test "count_distinct skips null" do
    assert eval_aggregate("count_distinct(x)", [[x: 1], [x: nil], [x: 1]]) == 1
    assert eval_aggregate("count_distinct(x)", [[x: nil], [x: nil]]) == 0
  end

  test "large query cardinalities stay within a sanity bound of the estimate" do
    n = 20_000
    estimate = eval_aggregate("count_distinct(x)", Enum.map(1..n, &[x: &1]))
    assert abs(estimate - n) <= n * 0.25
  end
end

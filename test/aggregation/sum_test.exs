defmodule Aggregation.SumTest do
  use Query.EvaluationTestCase, async: true

  test "sum" do
    assert eval_aggregate("sum(x)", []) == 0.0
    assert eval_aggregate("sum(x)", [[x: 1], [x: 2], [x: 3]]) == 6
  end

  test "sum with nil values" do
    assert eval_aggregate("sum(x)", [[x: nil], [x: nil]]) == nil
    assert eval_aggregate("sum(x)", [[x: 1], [x: nil], [x: 2]]) == 3
  end
end

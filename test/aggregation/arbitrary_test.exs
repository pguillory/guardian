defmodule Aggregation.ArbitraryTest do
  use Query.EvaluationTestCase, async: true

  test "arbitrary" do
    assert eval_aggregate("arbitrary(x)", []) == nil
    assert eval_aggregate("arbitrary(x)", [[x: 1], [x: 2], [x: 3]]) in [1, 2, 3]
  end

  test "arbitrary with nil values" do
    assert eval_aggregate("arbitrary(x)", [[x: nil], [x: nil]]) == nil
    assert eval_aggregate("arbitrary(x)", [[x: nil], [x: 1], [x: 2]]) in [nil, 1, 2]
  end
end

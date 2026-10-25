defmodule Guardian.Aggregation.CountIfTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "count_if" do
    assert eval_aggregate("count_if(x)", []) == 0
    assert eval_aggregate("count_if(x)", [[x: true], [x: true], [x: false]]) == 2
    assert eval_aggregate("count_if(x)", [[x: false], [x: false]]) == 0
    assert eval_aggregate("count_if(x)", [[x: true], [x: true], [x: true]]) == 3
  end

  test "count_if with nil values" do
    assert eval_aggregate("count_if(x)", [[x: nil], [x: true], [x: nil]]) == 1
  end
end

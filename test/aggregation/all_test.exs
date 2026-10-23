defmodule Aggregation.AllTest do
  use Query.EvaluationTestCase, async: true

  test "all" do
    assert eval_aggregate("all(x)", []) == true

    assert eval_aggregate("all(x)", [[x: true], [x: true]]) == true

    assert eval_aggregate("all(x)", [[x: true], [x: false]]) == false
    assert eval_aggregate("all(x)", [[x: false], [x: true]]) == false

    assert eval_aggregate("all(x)", [[x: true], [x: nil]]) == nil
    assert eval_aggregate("all(x)", [[x: nil], [x: true]]) == nil

    assert eval_aggregate("all(x)", [[x: false], [x: nil]]) == false
    assert eval_aggregate("all(x)", [[x: nil], [x: false]]) == false
  end
end

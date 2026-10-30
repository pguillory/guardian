defmodule Guardian.Aggregation.SumTest do
  use Guardian.Query.EvaluationTestCase, async: true
  import Guardian.Aggregation.Sum

  test "sum" do
    assert eval_aggregate("sum(x)", []) == nil
    assert eval_aggregate("sum(x)", [[x: 1], [x: 2], [x: 3]]) == 6
  end

  test "sum with nil values" do
    assert eval_aggregate("sum(x)", [[x: nil], [x: nil]]) == nil
    assert eval_aggregate("sum(x)", [[x: 1], [x: nil], [x: 2]]) == 3
  end

  test "an integer sum wraps to 64 bits like +" do
    max = Guardian.Query.Numeric.max_int()
    assert eval_aggregate("sum(x)", [[x: max], [x: 1]]) == Guardian.Query.Numeric.min_int()
    assert eval_aggregate("sum(x)", [[x: max], [x: 1], [x: -1]]) == max
  end

  test "a float sum that overflows is null, however later rows merge into it" do
    assert eval_aggregate("sum(x)", [[x: 1.0e308], [x: 1.0e308]]) == nil
    assert eval_aggregate("sum(x)", [[x: 1.0e308], [x: 1.0e308], [x: -1.0e308]]) == nil
    assert eval_aggregate("sum(x)", [[x: 1.0e308], [x: 1.0e308], [x: nil], [x: 1]]) == nil

    sum = Guardian.Aggregation.fetch!("sum")
    assert merge(:overflow, 1.0) == :overflow
    assert merge(nil, :overflow) == :overflow
    assert Guardian.Aggregation.finish(sum, :overflow) == nil
  end
end

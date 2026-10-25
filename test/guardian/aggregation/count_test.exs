defmodule Guardian.Aggregation.CountTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "count" do
    assert eval_aggregate("count()", []) == 0
    assert eval_aggregate("count()", [[], [], []]) == 3

    assert eval_aggregate("count(*)", []) == 0
    assert eval_aggregate("count(*)", [[], [], []]) == 3
  end
end

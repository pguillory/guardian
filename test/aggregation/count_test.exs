defmodule Aggregation.CountTest do
  use Query.EvaluationTestCase, async: true

  test "count" do
    assert eval_aggregate("count()", []) == 0
    assert eval_aggregate("count()", [[], [], []]) == 3

    assert eval_aggregate("count(*)", []) == 0
    assert eval_aggregate("count(*)", [[], [], []]) == 3
  end
end

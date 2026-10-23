defmodule Aggregation.MinByTest do
  use Query.EvaluationTestCase, async: true

  test "min_by" do
    rows = [
      [x: "a", y: 1],
      [x: "b", y: 2],
    ]

    assert eval_aggregate("min_by(x, y)", rows) == "a"
  end
end

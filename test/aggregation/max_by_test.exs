defmodule Aggregation.MaxByTest do
  use Query.EvaluationTestCase, async: true

  test "max_by" do
    rows = [
      [x: "a", y: 1],
      [x: "b", y: 2],
    ]

    assert eval_aggregate("max_by(x, y)", rows) == "b"
  end
end

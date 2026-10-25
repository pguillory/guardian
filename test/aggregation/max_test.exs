defmodule Guardian.Aggregation.MaxTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "max" do
    rows = [
      [x: 1],
      [x: 2],
    ]

    assert eval_aggregate("max(x)", rows) == 2
  end
end

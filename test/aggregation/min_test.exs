defmodule Guardian.Aggregation.MinTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "min" do
    rows = [
      [x: 1],
      [x: 2],
    ]

    assert eval_aggregate("min(x)", rows) == 1
  end
end

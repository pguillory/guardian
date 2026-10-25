defmodule Guardian.Aggregation.MinNTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "min_n" do
    rows = [
      [x: 5],
      [x: 1],
      [x: 3],
      [x: 3],
      [x: 8],
      [x: 9],
      [x: 2],
      [x: 2],
      [x: 7],
      [x: 3],
    ]

    assert eval_aggregate("min_n(x, 3)", rows) == [1, 2, 2]
  end
end

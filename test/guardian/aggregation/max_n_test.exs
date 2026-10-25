defmodule Guardian.Aggregation.MaxNTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "max_n" do
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

    assert eval_aggregate("max_n(x, 3)", rows) == [9, 8, 7]
  end
end

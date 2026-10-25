defmodule Guardian.Aggregation.MinNByTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "min_n_by" do
    rows = [
      [x: "a", y: 5],
      [x: "b", y: 1],
      [x: "c", y: 3],
      [x: "d", y: 3],
      [x: "e", y: 8],
      [x: "f", y: 9],
      [x: "g", y: 2],
      [x: "h", y: 2],
      [x: "i", y: 7],
      [x: "j", y: 3],
    ]

    assert eval_aggregate("min_n_by(x, y, 3)", rows) == ["b", "g", "h"]
  end
end

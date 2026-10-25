defmodule Guardian.AST.Node.Operators.SubtractOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "subtract operator" do
    assert eval("123 - 123") === 0
    assert eval("123 - 4.5") === 118.5
    assert eval("4.5 - 123") === -118.5
    assert eval("4.5 - 4.5") === 0.0

    assert eval("123 - null") == nil
    assert eval("null - 123") == nil

    assert eval("4.5 - null") == nil
    assert eval("null - 4.5") == nil

    assert eval("null - null") == nil

    assert eval("'2024-01-02 03:04:05' - 5") == "2024-01-02 03:04:00"
    assert eval("'asdf' - 5") == nil
  end

  test "a timestamp minus seconds over two columns matches per-event evaluation" do
    rows = [
      %{t: "2020-01-01 00:00:00", n: 60},
      %{t: "2020-01-02 00:00:00", n: -1},
      %{t: "not a time", n: 1},
      %{t: 5, n: 1},
      %{t: nil, n: 1},
    ]

    expected = ["2019-12-31 23:59:00", "2020-01-02 00:00:01", nil, 4, nil]
    assert eval_segment_and_rows("t - n", rows) == {expected, expected}

    # Seconds minus a timestamp is no timestamp.
    assert eval_segment_and_rows("n - t", rows) ==
             {[nil, nil, nil, -4, nil], [nil, nil, nil, -4, nil]}
  end
end

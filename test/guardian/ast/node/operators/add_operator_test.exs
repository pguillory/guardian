defmodule Guardian.AddOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "add operator" do
    assert eval("123 + 123") === 246
    assert eval("123 + 4.5") === 127.5
    assert eval("4.5 + 123") === 127.5
    assert eval("4.5 + 4.5") === 9.0

    assert eval("123 + null") == nil
    assert eval("null + 123") == nil

    assert eval("4.5 + null") == nil
    assert eval("null + 4.5") == nil

    assert eval("null + null") == nil

    assert eval("'2024-01-02 03:04:05' + 5") == "2024-01-02 03:04:10"
    assert eval("5 + '2024-01-02 03:04:05'") == "2024-01-02 03:04:10"
    assert eval("'asdf' + 5") == nil
  end

  test "a timestamp plus seconds over two columns matches per-event evaluation" do
    rows = [
      %{t: "2020-01-01 00:00:00", n: 60},
      %{t: "2020-01-02 00:00:00", n: -1},
      %{t: "not a time", n: 1},
      %{t: 5, n: 1},
      %{t: "2020-01-01 00:00:00", n: 1.5},
      %{t: nil, n: 1},
    ]

    expected = ["2020-01-01 00:01:00", "2020-01-01 23:59:59", nil, 6, nil, nil]
    assert eval_segment_and_rows("t + n", rows) == {expected, expected}
    assert eval_segment_and_rows("n + t", rows) == {expected, expected}
  end
end

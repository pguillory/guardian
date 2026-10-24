defmodule Query.Function.DateAddTest do
  use Query.EvaluationTestCase, async: true

  test "date_add function" do
    assert eval("date_add('2024-01-02 03:04:05', 5)") == "2024-01-02 03:04:10"
    assert eval("date_add('asdf', 5)") == nil

    assert eval("date_add(nil, 5)") == nil
    assert eval("date_add('2024-01-02 03:04:05', nil)") == nil
  end

  test "a timestamp with a UTC offset is shifted to UTC" do
    assert eval("date_add(a, 5)", a: "2024-01-02T05:04:05+02:00") == "2024-01-02 03:04:10"
    assert eval("a + 5", a: "2024-01-02T05:04:05+02:00") == "2024-01-02 03:04:10"
    assert eval("to_seconds(a)", a: "1970-01-01T01:00:00+01:00") == 0
    assert eval("date_sub(a, 5)", a: "2024-01-02T03:04:05.9-01:00") == "2024-01-02 04:04:00"
    assert eval("a - 5", a: "2024-01-02T03:04:05.9-01:00") == "2024-01-02 04:04:00"
  end
end

defmodule Guardian.Query.Function.DateAddTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "date_add function" do
    assert eval("date_add('2024-01-02 03:04:05', 5)") == "2024-01-02 03:04:10"
    assert eval("date_add('asdf', 5)") == nil

    assert eval("date_add(nil, 5)") == nil
    assert eval("date_add('2024-01-02 03:04:05', nil)") == nil
  end
end

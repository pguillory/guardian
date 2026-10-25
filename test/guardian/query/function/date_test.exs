defmodule Guardian.Query.Function.DateTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "date function" do
    assert eval("date('2024-01-02 03:04:05')") === "2024-01-02"
  end

  test "no args" do
    assert eval("date()") == eval("date(now())")
  end
end

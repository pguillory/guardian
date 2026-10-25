defmodule Guardian.Query.Function.RpadTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "rpad function" do
    assert eval("rpad('abc', 5)") === "abc  "
    assert eval("rpad('abc', 1)") === "abc"
  end
end

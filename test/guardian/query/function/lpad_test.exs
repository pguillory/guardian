defmodule Guardian.Query.Function.LpadTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "lpad function" do
    assert eval("lpad('abc', 5)") === "  abc"
    assert eval("lpad('abc', 1)") === "abc"
  end
end

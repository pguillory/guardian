defmodule Guardian.Query.Function.AbsTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "abs function" do
    assert eval("abs(1.5)") === 1.5
    assert eval("abs(-1.5)") === 1.5
  end
end

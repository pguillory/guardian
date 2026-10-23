defmodule Query.Function.AbsTest do
  use Query.EvaluationTestCase, async: true

  test "abs function" do
    assert eval("abs(1.5)") === 1.5
    assert eval("abs(-1.5)") === 1.5
  end
end

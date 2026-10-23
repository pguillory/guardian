defmodule Query.Function.DivTest do
  use Query.EvaluationTestCase, async: true

  test "div function" do
    assert eval("div(10, 3)") === 3
  end
end

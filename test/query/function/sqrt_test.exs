defmodule Guardian.Query.Function.SqrtTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "sqrt function" do
    assert eval("sqrt(2.0)") === 1.4142135623730951
  end
end

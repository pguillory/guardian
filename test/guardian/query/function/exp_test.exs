defmodule Guardian.Query.Function.ExpTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "exp function" do
    assert eval("exp(1.0)") === 2.718281828459045
  end
end

defmodule Guardian.AST.Node.Operators.NegativeOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "negative operator" do
    assert eval("-null") == nil
    assert eval("-false") == nil
    assert eval("-true") == nil
    assert eval("-123") == -123
    assert eval("-4.5") == -4.5
    assert eval("-'abc'") == nil
  end
end

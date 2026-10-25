defmodule Guardian.AST.Node.Operators.IsNotOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "is not operator" do
    assert eval("1 is not 2") == true
    assert eval("1 is not 1") == false
    assert eval("2 is not 1") == true

    assert eval("nil is not 2") == true
    assert eval("nil is not nil") == false
    assert eval("2 is not nil") == true
  end
end

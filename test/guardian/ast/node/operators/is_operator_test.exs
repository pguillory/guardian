defmodule Guardian.AST.Node.Operators.IsOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "is operator" do
    assert eval("1 is 2") == false
    assert eval("1 is 1") == true
    assert eval("2 is 1") == false

    assert eval("nil is 2") == false
    assert eval("nil is nil") == true
    assert eval("2 is nil") == false
  end
end

defmodule Guardian.AST.Node.IdentifierTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "identifiers" do
    assert eval("a", a: 1) == 1
    assert eval("b", a: 1) == nil
  end
end

defmodule Guardian.AST.Node.ListLiteralTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "list literal" do
    assert eval("[]") == []
    assert eval("[null]") == [nil]
    assert eval("[false]") == [false]
    assert eval("[true]") == [true]
    assert eval("[123]") == [123]
    assert eval("[4.5]") == [4.5]
    assert eval("['abc']") == ["abc"]
  end
end

defmodule Guardian.AST.Node.Operators.ConcatOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "concat operator" do
    assert eval("'a' || 'b'") === "ab"
    assert eval("'a' || null") === "a"
    assert eval("null || 'b'") === "b"
    assert eval("null || null") === ""
  end
end

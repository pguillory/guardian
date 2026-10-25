defmodule Guardian.AST.Node.Operators.AndOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "and operator" do
    assert eval("true and true") == true
    assert eval("true and false") == false
    assert eval("false and true") == false
    assert eval("false and false") == false

    assert eval("null and null") == nil
    assert eval("null and false") == false
    assert eval("null and true") == nil
    assert eval("null and 123") == nil
    assert eval("null and 4.5") == nil
    assert eval("null and 'a'") == nil

    assert eval("null and null") == nil
    assert eval("false and null") == false
    assert eval("true and null") == nil
    assert eval("123 and null") == nil
    assert eval("4.5 and null") == nil
    assert eval("'a' and null") == nil
  end
end

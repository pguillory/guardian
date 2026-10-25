defmodule Guardian.OrOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "or operator" do
    assert eval("true or true") == true
    assert eval("true or false") == true
    assert eval("false or true") == true
    assert eval("false or false") == false

    assert eval("null or null") == nil
    assert eval("null or false") == nil
    assert eval("null or true") == true
    assert eval("null or 123") == nil
    assert eval("null or 4.5") == nil
    assert eval("null or 'a'") == nil

    assert eval("null or null") == nil
    assert eval("false or null") == nil
    assert eval("true or null") == true
    assert eval("123 or null") == nil
    assert eval("4.5 or null") == nil
    assert eval("'a' or null") == nil
  end
end

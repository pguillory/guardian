defmodule Guardian.MultiplyOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "multiply operator" do
    assert eval("123 * 123") === 15129
    assert eval("123 * 4.5") === 553.5
    assert eval("4.5 * 123") === 553.5
    assert eval("4.5 * 4.5") === 20.25

    assert eval("123 * null") == nil
    assert eval("null * 123") == nil

    assert eval("4.5 * null") == nil
    assert eval("null * 4.5") == nil

    assert eval("null * null") == nil
  end
end

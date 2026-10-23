defmodule DivideOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "divide operator" do
    assert eval("123 / 123") === 1.0
    assert eval("123 / 4.5") === 27.333333333333332
    assert eval("4.5 / 123") === 0.036585365853658534
    assert eval("4.5 / 4.5") === 1.0

    assert eval("123 / null") == nil
    assert eval("null / 123") == nil

    assert eval("4.5 / null") == nil
    assert eval("null / 4.5") == nil

    assert eval("null / null") == nil

    assert eval("1 / 0") == nil
  end
end

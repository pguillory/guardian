defmodule Query.Function.ToBooleanTest do
  use Query.EvaluationTestCase, async: true

  test "to_boolean function" do
    assert eval("to_boolean(x)", x: nil) === nil
    assert eval("to_boolean(x)", x: false) === false
    assert eval("to_boolean(x)", x: true) === true
    assert eval("to_boolean(x)", x: 123) === nil
    assert eval("to_boolean(x)", x: 4.5) === nil
    assert eval("to_boolean(x)", x: "abc") === nil
  end
end

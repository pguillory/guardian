defmodule Query.Function.ToStringTest do
  use Query.EvaluationTestCase, async: true

  test "to_string function" do
    assert eval("to_string(x)", x: nil) === nil
    assert eval("to_string(x)", x: false) === nil
    assert eval("to_string(x)", x: true) === nil
    assert eval("to_string(x)", x: 123) === nil
    assert eval("to_string(x)", x: 4.5) === nil
    assert eval("to_string(x)", x: "abc") === "abc"
  end
end

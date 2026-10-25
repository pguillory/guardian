defmodule Guardian.Query.Function.LowerTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "lower function" do
    assert eval("lower('Abc')") === "abc"
  end
end

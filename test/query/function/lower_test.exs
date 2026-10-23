defmodule Query.Function.LowerTest do
  use Query.EvaluationTestCase, async: true

  test "lower function" do
    assert eval("lower('Abc')") === "abc"
  end
end

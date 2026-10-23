defmodule Query.Function.UpperTest do
  use Query.EvaluationTestCase, async: true

  test "upper function" do
    assert eval("upper('Abc')") === "ABC"
  end
end

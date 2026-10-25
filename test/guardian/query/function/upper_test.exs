defmodule Guardian.Query.Function.UpperTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "upper function" do
    assert eval("upper('Abc')") === "ABC"
  end
end

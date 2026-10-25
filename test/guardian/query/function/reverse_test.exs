defmodule Guardian.Query.Function.ReverseTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "reverse function" do
    assert eval("reverse('Abc')") === "cbA"
  end
end

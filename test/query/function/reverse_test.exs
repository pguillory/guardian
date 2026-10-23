defmodule Query.Function.ReverseTest do
  use Query.EvaluationTestCase, async: true

  test "reverse function" do
    assert eval("reverse('Abc')") === "cbA"
  end
end

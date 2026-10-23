defmodule Query.Function.FactorialTest do
  use Query.EvaluationTestCase, async: true

  test "factorial function" do
    assert eval("factorial(5)") === 120
  end
end

defmodule Guardian.Query.Function.RoundTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "round function" do
    assert eval("round(1.5)") === 2
  end
end

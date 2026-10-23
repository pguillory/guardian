defmodule Query.Function.RoundTest do
  use Query.EvaluationTestCase, async: true

  test "round function" do
    assert eval("round(1.5)") === 2
  end
end

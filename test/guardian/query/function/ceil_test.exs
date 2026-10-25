defmodule Guardian.Query.Function.CeilTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "ceil function" do
    assert eval("ceil(1.5)") === 2
  end
end

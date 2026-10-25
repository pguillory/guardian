defmodule Guardian.Query.Function.PowerTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "power function" do
    assert eval("power(9, 3)") === 729.0
  end
end

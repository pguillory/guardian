defmodule Guardian.Query.Function.FloorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "floor function" do
    assert eval("floor(1.5)") === 1
  end
end

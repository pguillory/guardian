defmodule Query.Function.FloorTest do
  use Query.EvaluationTestCase, async: true

  test "floor function" do
    assert eval("floor(1.5)") === 1
  end
end

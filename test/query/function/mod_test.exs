defmodule Query.Function.ModTest do
  use Query.EvaluationTestCase, async: true

  test "mod function" do
    assert eval("mod(10, 3)") === 1
  end
end

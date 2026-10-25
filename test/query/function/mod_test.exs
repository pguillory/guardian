defmodule Guardian.Query.Function.ModTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "mod function" do
    assert eval("mod(10, 3)") === 1
  end
end

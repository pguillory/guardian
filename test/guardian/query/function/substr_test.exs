defmodule Guardian.Query.Function.SubstrTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "substr function" do
    assert eval("substr('Abc', 1)") == "Abc"
    assert eval("substr('Abc', 2)") == "bc"
    assert eval("substr('Abc', 1, 1)") == "A"
    assert eval("substr('Abc', 2, 1)") == "b"
  end
end

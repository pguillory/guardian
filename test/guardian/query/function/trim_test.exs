defmodule Guardian.Query.Function.TrimTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "trim function" do
    assert eval("trim(' a b ')") === "a b"
  end
end

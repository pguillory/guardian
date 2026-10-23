defmodule Query.Function.TrimTest do
  use Query.EvaluationTestCase, async: true

  test "trim function" do
    assert eval("trim(' a b ')") === "a b"
  end
end

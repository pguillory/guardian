defmodule Query.Function.ToSecondsTest do
  use Query.EvaluationTestCase, async: true

  test "to_seconds function" do
    assert eval("to_seconds('2024-01-02 03:04:05')") === 1_704_164_645
  end
end

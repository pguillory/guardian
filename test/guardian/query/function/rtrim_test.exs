defmodule Guardian.Query.Function.RtrimTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "rtrim function" do
    assert eval("rtrim(' a b ')") === " a b"
  end
end

defmodule Query.Function.RtrimTest do
  use Query.EvaluationTestCase, async: true

  test "rtrim function" do
    assert eval("rtrim(' a b ')") === " a b"
  end
end

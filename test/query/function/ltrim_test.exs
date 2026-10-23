defmodule Query.Function.LtrimTest do
  use Query.EvaluationTestCase, async: true

  test "ltrim function" do
    assert eval("ltrim(' a b ')") === "a b "
  end
end

defmodule Query.Function.LogTest do
  use Query.EvaluationTestCase, async: true

  test "log function" do
    assert eval("log(2.0)") === 0.6931471805599453
  end
end

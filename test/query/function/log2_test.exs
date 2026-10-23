defmodule Query.Function.Log2Test do
  use Query.EvaluationTestCase, async: true

  test "log2 function" do
    assert eval("log2(8)") === 3.0
  end
end

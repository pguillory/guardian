defmodule Guardian.Query.Function.Log10Test do
  use Guardian.Query.EvaluationTestCase, async: true

  test "log10 function" do
    assert eval("log10(1000)") === 3.0
  end
end

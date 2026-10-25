defmodule Guardian.BetweenOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "between operator" do
    assert eval("1 between 2 and 3") == false
    assert eval("2 between 2 and 3") == true
    assert eval("3 between 2 and 3") == true
    assert eval("4 between 2 and 3") == false
  end
end

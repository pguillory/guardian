defmodule Guardian.NotEqualOperatorTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "not equal operator" do
    assert eval("1 != 2") == true
    assert eval("1 != 1") == false
    assert eval("2 != 1") == true

    assert eval("1.0 != 2.0") == true
    assert eval("1.0 != 1.0") == false
    assert eval("2.0 != 1.0") == true

    assert eval("1.0 != 2") == true
    assert eval("1.0 != 1") == false
    assert eval("2.0 != 1") == true

    assert eval("1 != 2.0") == true
    assert eval("1 != 1.0") == false
    assert eval("2 != 1.0") == true

    assert eval("nil = 2") == nil
    assert eval("nil = nil") == nil
    assert eval("2 = nil") == nil
  end
end

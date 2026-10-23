defmodule InOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "in operator" do
    assert eval("1 in [1, 2]") == true
    assert eval("2 in [1, 2]") == true
    assert eval("3 in [1, 2]") == false
    assert eval("null in [1, 2]") == nil

    assert eval("1 in [null, 2, 3]") == nil
    assert eval("2 in [null, 2, 3]") == true
    assert eval("3 in [null, 2, 3]") == true
    assert eval("null in [null, 2, 3]") == nil

    assert eval("1 in [1, null, 3]") == true
    assert eval("2 in [1, null, 3]") == nil
    assert eval("3 in [1, null, 3]") == true
    assert eval("null in [1, null, 3]") == nil

    assert eval("1 in [1, 2, null]") == true
    assert eval("2 in [1, 2, null]") == true
    assert eval("3 in [1, 2, null]") == nil
    assert eval("null in [1, 2, null]") == nil
  end
end

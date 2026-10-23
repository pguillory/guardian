defmodule AddOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "add operator" do
    assert eval("123 + 123") === 246
    assert eval("123 + 4.5") === 127.5
    assert eval("4.5 + 123") === 127.5
    assert eval("4.5 + 4.5") === 9.0

    assert eval("123 + null") == nil
    assert eval("null + 123") == nil

    assert eval("4.5 + null") == nil
    assert eval("null + 4.5") == nil

    assert eval("null + null") == nil

    assert eval("'2024-01-02 03:04:05' + 5") == "2024-01-02 03:04:10"
    assert eval("5 + '2024-01-02 03:04:05'") == "2024-01-02 03:04:10"
    assert eval("'asdf' + 5") == nil
  end
end

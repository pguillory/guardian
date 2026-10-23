defmodule SubtractOperatorTest do
  use Query.EvaluationTestCase, async: true

  test "subtract operator" do
    assert eval("123 - 123") === 0
    assert eval("123 - 4.5") === 118.5
    assert eval("4.5 - 123") === -118.5
    assert eval("4.5 - 4.5") === 0.0

    assert eval("123 - null") == nil
    assert eval("null - 123") == nil

    assert eval("4.5 - null") == nil
    assert eval("null - 4.5") == nil

    assert eval("null - null") == nil

    assert eval("'2024-01-02 03:04:05' - 5") == "2024-01-02 03:04:00"
    assert eval("'asdf' - 5") == nil
  end
end

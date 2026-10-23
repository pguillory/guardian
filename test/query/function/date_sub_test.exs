defmodule Query.Function.DateSubTest do
  use Query.EvaluationTestCase, async: true

  test "date_sub function" do
    assert eval("date_sub('2024-01-02 03:04:05', 5)") == "2024-01-02 03:04:00"
    assert eval("date_sub('asdf', 5)") == nil

    assert eval("date_sub(nil, 5)") == nil
    assert eval("date_sub('2024-01-02 03:04:05', nil)") == nil
  end
end

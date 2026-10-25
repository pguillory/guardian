defmodule Guardian.Query.Function.NowTest do
  use Guardian.Query.EvaluationTestCase, async: false

  test "now function" do
    time1 = Guardian.Timestamp.now()
    now = eval("now()")
    time2 = Guardian.Timestamp.now()
    assert now in [time1, time2]
  end
end

defmodule Query.Function.NowTest do
  use Query.EvaluationTestCase, async: false

  test "now function" do
    time1 = Timestamp.now()
    now = eval("now()")
    time2 = Timestamp.now()
    assert now in [time1, time2]
  end
end

defmodule Guardian.Query.Function.NowTest do
  # Not async: now() has one-second granularity and eval/2 requires four evaluations to
  # agree, so a tick mid-test fails it; load makes that likelier.
  use Guardian.Query.EvaluationTestCase, async: false

  test "now function" do
    time1 = Guardian.Timestamp.now()
    now = eval("now()")
    time2 = Guardian.Timestamp.now()
    assert now in [time1, time2]
  end
end

defmodule Guardian.Query.Function.NowTest do
  use ExUnit.Case, async: true
  import Guardian.Test.Query, only: [run_sql: 1]

  # One query, one evaluation: now() lies between the clock reads around it, even if the
  # second ticks in between.
  test "now function" do
    time1 = Guardian.Timestamp.now()
    [[now]] = run_sql("SELECT now()")
    time2 = Guardian.Timestamp.now()
    # Timestamps are fixed-width strings, so they compare in time order.
    assert time1 <= now and now <= time2
  end
end

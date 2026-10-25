defmodule Guardian.Query.Function.IntervalTest do
  use Guardian.Query.EvaluationTestCase, async: true
  alias Guardian.Query.Function.Interval

  # test "interval function" do
  #   assert eval("interval('1h')") === 3600
  #   assert eval("interval('asdf')") === nil
  #   assert eval("interval(nil)") === nil
  # end

  test "MySQL interval syntax" do
    assert eval("interval 1 second") === 1
    assert eval("interval 1 minute") === 60
    assert eval("interval 1 hour") === 60 * 60
    assert eval("interval 1 day") === 60 * 60 * 24
    assert eval("interval 1 week") === 60 * 60 * 24 * 7
  end

  test "to_seconds" do
    assert Interval.to_seconds("") == {:ok, 0}
    assert Interval.to_seconds("1s") == {:ok, 1}
    assert Interval.to_seconds("1m") == {:ok, 60}
    assert Interval.to_seconds("1h") == {:ok, 3600}
    assert Interval.to_seconds("1d") == {:ok, 86400}
    assert Interval.to_seconds("1w") == {:ok, 604_800}
    assert Interval.to_seconds("2w 2d 2h 2m 2s") == {:ok, 1_389_722}
    1_389_722 = 2 * 604_800 + 2 * 86400 + 2 * 3600 + 2 * 60 + 2

    assert Interval.to_seconds("asdf") == :error
  end

  test "from_seconds" do
    assert Interval.from_seconds(0) == ""
    assert Interval.from_seconds(1) == "1s"
    assert Interval.from_seconds(60) == "1m"
    assert Interval.from_seconds(3600) == "1h"
    assert Interval.from_seconds(86400) == "1d"
    assert Interval.from_seconds(604_800) == "1w"
    assert Interval.from_seconds(1_389_722) == "2w2d2h2m2s"
  end
end

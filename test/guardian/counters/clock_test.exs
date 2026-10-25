defmodule Guardian.Counters.ClockTest do
  use ExUnit.Case, async: true

  alias Guardian.Counters.Clock

  test "now is the local monotonic microsecond clock" do
    before = System.monotonic_time(:microsecond)
    now = Clock.now()
    assert before <= now
    assert now <= System.monotonic_time(:microsecond)
  end

  test "from_ms converts a millisecond duration to microseconds" do
    assert Clock.from_ms(0) == 0
    assert Clock.from_ms(50) == 50_000
    assert Clock.from_ms(-3) == -3_000
  end

  test "deadline anchors a millisecond duration on the local clock" do
    before = Clock.now()
    deadline = Clock.deadline(100)
    after_capture = Clock.now()
    assert before + 100_000 <= deadline
    assert deadline <= after_capture + 100_000
  end

  test "remaining_ms truncates whole milliseconds and never goes negative" do
    assert Clock.remaining_ms(Clock.now() - 5_000) == 0

    deadline = Clock.now() + 10_000_000
    before = Clock.now()
    remaining = Clock.remaining_ms(deadline)
    after_capture = Clock.now()
    assert max(0, div(deadline - after_capture, 1_000)) <= remaining
    assert remaining <= max(0, div(deadline - before, 1_000))
  end

  test "to_store_ms floors to a monotonic millisecond instant" do
    assert Clock.to_store_ms(1_999) == 1
    assert Clock.to_store_ms(2_000) == 2
    assert Clock.to_store_ms(-1) == -1
    assert Clock.to_store_ms(-1_000) == -1
    assert Clock.to_store_ms(-1_001) == -2

    before = System.monotonic_time(:millisecond)
    store_ms = Clock.to_store_ms(Clock.now())
    assert before <= store_ms
    assert store_ms <= System.monotonic_time(:millisecond)
  end
end

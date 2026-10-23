defmodule SystemStatsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  test "records system_stats events through normal ingestion" do
    count_before = Storage.table_row_count("system_stats")

    assert :ok = SystemStats.record_metrics()
    assert Storage.table_row_count("system_stats") > count_before
  end

  test "stamps each system_stats event with a UTC timestamp" do
    timestamp = Keyword.fetch!(SystemStats.metrics(), :timestamp)

    assert {:ok, recorded} = NaiveDateTime.from_iso8601(timestamp)
    assert timestamp == NaiveDateTime.to_string(recorded)
    assert abs(NaiveDateTime.diff(NaiveDateTime.utc_now(), recorded)) < 5
  end

  # Delivers a tick now and waits until it has been handled.
  defp tick(stats) do
    send(stats, {:tick, System.monotonic_time(:millisecond)})
    :sys.get_state(stats)
  end

  test "skips writes while Storage is down, warning once" do
    stats = start_supervised!(SystemStats)

    log =
      capture_log(fn ->
        :ok = Supervisor.terminate_child(Storage, Storage.MutableSegments)
        on_exit(fn -> Supervisor.restart_child(Storage, Storage.MutableSegments) end)

        for _ <- 1..5, do: assert(tick(stats) == %{failing: true})

        {:ok, _pid} = Supervisor.restart_child(Storage, Storage.MutableSegments)
        assert tick(stats) == %{failing: false}
      end)

    assert Process.alive?(stats)
    warning = "SystemStats: could not record system_stats (ArgumentError)"
    # The application's own SystemStats may warn once too in this window; five failed
    # ticks of this one must not warn five times.
    assert (length(String.split(log, warning)) - 1) in 1..2
  end
end

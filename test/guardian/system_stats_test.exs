defmodule Guardian.SystemStatsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  test "records system_stats events through normal ingestion" do
    count_before = Guardian.Storage.table_row_count("system_stats")

    assert :ok = Guardian.SystemStats.record_metrics()
    assert Guardian.Storage.table_row_count("system_stats") > count_before
  end

  test "stamps each system_stats event with a UTC timestamp" do
    timestamp = Keyword.fetch!(Guardian.SystemStats.metrics(), :timestamp)

    assert {:ok, recorded} = NaiveDateTime.from_iso8601(timestamp)
    assert timestamp == NaiveDateTime.to_string(recorded)
    assert abs(NaiveDateTime.diff(NaiveDateTime.utc_now(), recorded)) < 5
  end

  test "counter availability is visible in metrics while health remains Storage-only" do
    assert Keyword.fetch!(Guardian.SystemStats.metrics(), :counters_available) == true
    :ok = Supervisor.terminate_child(Guardian.Application, Guardian.Counters.Restarter)

    try do
      assert Keyword.fetch!(Guardian.SystemStats.metrics(), :counters_available) == false
      conn = Plug.Test.conn(:get, "/health") |> Guardian.Web.MainRouter.call(nil)
      assert conn.status == 200
      assert conn.resp_body == "ok"
    after
      {:ok, _} = Supervisor.restart_child(Guardian.Application, Guardian.Counters.Restarter)
    end

    assert Keyword.fetch!(Guardian.SystemStats.metrics(), :counters_available) == true
  end

  # Delivers a tick now and waits until it has been handled.
  defp tick(stats) do
    send(stats, {:tick, System.monotonic_time(:millisecond)})
    :sys.get_state(stats)
  end

  test "skips writes while Storage is down, warning once" do
    stats = start_supervised!(Guardian.SystemStats)

    log =
      capture_log(fn ->
        :ok = Supervisor.terminate_child(Guardian.Storage, Guardian.Storage.MutableSegments)

        on_exit(fn ->
          Supervisor.restart_child(Guardian.Storage, Guardian.Storage.MutableSegments)
        end)

        for _ <- 1..5, do: assert(tick(stats) == %{failing: true})

        {:ok, _pid} = Supervisor.restart_child(Guardian.Storage, Guardian.Storage.MutableSegments)
        assert tick(stats) == %{failing: false}
      end)

    assert Process.alive?(stats)
    warning = "SystemStats: could not record system_stats (ArgumentError)"
    # The application's own SystemStats may warn once too in this window; five failed
    # ticks of this one must not warn five times.
    assert (length(String.split(log, warning)) - 1) in 1..2
  end
end

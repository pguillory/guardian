defmodule Guardian.SystemStatsTest do
  # Not async: counts rows of the shared system_stats table.
  use ExUnit.Case, async: false
  import Guardian.SystemStats

  test "records system_stats events through normal ingestion" do
    count_before = Guardian.Storage.table_row_count("system_stats")

    assert :ok = record_metrics()
    assert Guardian.Storage.table_row_count("system_stats") > count_before
  end

  test "stamps each system_stats event with a UTC timestamp" do
    before_metrics = NaiveDateTime.utc_now(:second)
    timestamp = Keyword.fetch!(metrics(), :timestamp)
    after_metrics = NaiveDateTime.utc_now(:second)

    assert {:ok, recorded} = NaiveDateTime.from_iso8601(timestamp)
    assert timestamp == NaiveDateTime.to_string(recorded)
    assert NaiveDateTime.compare(recorded, before_metrics) in [:eq, :gt]
    assert NaiveDateTime.compare(recorded, after_metrics) in [:eq, :lt]
  end

  test "metrics report counters as available" do
    assert Keyword.fetch!(metrics(), :counters_available) == true
  end
end

defmodule Guardian.SystemStatsTest do
  # Other tests only add system_stats rows, so a growing count holds concurrently.
  use ExUnit.Case, async: true
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

  test "metrics report open descriptors, native storage counts and resident memory" do
    metrics = metrics()

    for key <- [:mmap_count, :native_column_count] do
      assert is_integer(Keyword.fetch!(metrics, key)) and Keyword.fetch!(metrics, key) >= 0
    end

    if Enum.any?(["/proc/self/fd", "/dev/fd"], &match?({:ok, _}, File.ls(&1))) do
      count = Keyword.fetch!(metrics, :open_fd_count)
      assert is_integer(count) and count > 0
    else
      assert Keyword.fetch!(metrics, :open_fd_count) == nil
    end

    case File.read("/proc/self/status") do
      {:ok, status} ->
        if status =~ ~r/^VmRSS:/m do
          bytes = Keyword.fetch!(metrics, :rss_bytes)
          assert is_integer(bytes) and bytes > 0
        else
          assert Keyword.fetch!(metrics, :rss_bytes) == nil
        end

      {:error, _reason} ->
        assert Keyword.fetch!(metrics, :rss_bytes) == nil
    end
  end
end

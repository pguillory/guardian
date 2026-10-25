defmodule Guardian.Storage.SegmentExpiration do
  # Internal to Storage; see lib/storage/CLAUDE.md, "Public boundary".
  @moduledoc false

  alias Guardian.Storage.LoadedSegments
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    send(self(), :tick)
    state = nil
    {:ok, state}
  end

  def handle_info(:tick, state) do
    tick()
    Process.send_after(self(), :tick, 600_000)
    {:noreply, state}
  end

  @seconds 1
  @minutes 60 * @seconds
  @hours 60 * @minutes
  @days 24 * @hours

  @max_age_days 15.0

  # Also expires skipped (unreadable) segment files, so they do not outlive the
  # retention period.
  def tick do
    # Skipped IDs are read first, as they always were.
    skipped_ids = LoadedSegments.skipped_segment_ids()

    Enum.concat(LoadedSegments.all_segment_ids(), skipped_ids)
    |> Enum.each(fn segment_id ->
      timestamp_nanoseconds = Guardian.SegmentID.get_timestamp_nanoseconds(segment_id)
      age_nanoseconds = System.os_time(:nanosecond) - timestamp_nanoseconds
      age_seconds = System.convert_time_unit(age_nanoseconds, :nanosecond, :second)
      age_days = age_seconds / @days

      if age_days > @max_age_days do
        IO.puts("Expiring segment #{segment_id} (#{Float.round(age_days, 1)} days old)")
        LoadedSegments.delete_segment(segment_id)
      end
    end)
  end
end

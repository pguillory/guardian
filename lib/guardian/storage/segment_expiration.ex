defmodule Guardian.Storage.SegmentExpiration do
  # Internal to Storage; see lib/guardian/storage/AGENTS.md, "Public boundary".
  @moduledoc false

  alias Guardian.Storage.BlobStore
  alias Guardian.Storage.LoadedSegments
  alias Guardian.Storage.SegmentFile
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

  # Goes by the files on disk, not the loaded segments, so a file that isn't loaded (it
  # was unreadable, or its segment crashed) doesn't outlive the retention period. A
  # file being written has a temporary name, which doesn't parse as a segment.
  def tick do
    {:ok, filenames} = BlobStore.list(Guardian.Storage.segment_dir())

    Enum.each(filenames, fn filename ->
      with {:ok, table, segment_id} <- SegmentFile.parse_filename(filename),
           true <- age_days(segment_id) > @max_age_days do
        LoadedSegments.delete_file(table, segment_id)
      end
    end)
  end

  defp age_days(segment_id) do
    timestamp_nanoseconds = Guardian.SegmentID.get_timestamp_nanoseconds(segment_id)
    age_nanoseconds = System.os_time(:nanosecond) - timestamp_nanoseconds
    age_seconds = System.convert_time_unit(age_nanoseconds, :nanosecond, :second)
    age_seconds / @days
  end
end

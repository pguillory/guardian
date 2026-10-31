defmodule Guardian.Storage.ReadableSegments do
  # Internal to Storage; see lib/guardian/storage/AGENTS.md, "Public boundary".
  @moduledoc false

  # The registry of every segment queries can read, from its creation (MutableSegments
  # registers each new segment here before using it) until it expires or is deleted,
  # through freezing and persisting: one process the whole time. It loads every file at
  # startup, and owns expiry and deletion. It monitors its segments rather than linking
  # them: a segment that dies drops out, and SegmentSupervisor logs the crash.

  alias Guardian.Storage.BlobStore
  alias Guardian.Storage.Segment
  alias Guardian.Storage.Segment.Registration
  alias Guardian.Storage.SegmentFile
  require Logger
  require Registration
  use GenServer

  @loading Module.concat(__MODULE__, Loading)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a new segment, as MutableSegments does before it takes rows.
  """
  def insert(registration) do
    GenServer.call(__MODULE__, {:insert, registration})
  end

  def segment_ids(table) do
    Registration.segment_ids(__MODULE__, table)
  end

  def get_segment(segment_id) do
    Registration.lookup(__MODULE__, segment_id)
  end

  @doc """
  Stops a segment and deletes its file, if it has one.
  """
  def delete_segment(segment_id) do
    GenServer.call(__MODULE__, {:delete_segment, segment_id}, :infinity)
  end

  @doc """
  Deletes a segment file and stops its segment if one is registered. Expiry uses this,
  since a file on disk isn't always loaded.
  """
  def delete_file(table, segment_id) do
    GenServer.call(__MODULE__, {:delete_file, table, segment_id}, :infinity)
  end

  # Loads into a table under another name and renames it when every file is in, so
  # until then `segment_ids/1` and `get_segment/1` raise (no table) instead of listing
  # some of the data as if it were all: a query during a reload fails rather than
  # returning a partial answer.
  def init(_opts) do
    @loading = :ets.new(@loading, [:named_table, :ordered_set])
    load_all_segments_from_disk()
    __MODULE__ = :ets.rename(@loading, __MODULE__)
    {:ok, nil}
  end

  def handle_call({:insert, registration}, _, state) do
    :ok = Registration.register(__MODULE__, registration)
    {:reply, :ok, state}
  end

  def handle_call({:delete_segment, segment_id}, _, state) do
    case :ets.lookup(__MODULE__, segment_id) do
      [Registration.tuple(table: table)] -> delete_file_and_segment(table, segment_id)
      [] -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:delete_file, table, segment_id}, _, state) do
    delete_file_and_segment(table, segment_id)
    {:reply, :ok, state}
  end

  # Matches by PID, so a late DOWN from a segment already deleted finds nothing.
  def handle_info({:DOWN, _ref, :process, segment, _reason}, state) do
    :ok = Registration.unregister(__MODULE__, segment)
    {:noreply, state}
  end

  # Stops the segment first, then deletes the file: a segment busy writing its file
  # finishes before it stops, so the file is gone for good. A writable segment has no
  # file, which is not worth a log line. A file that cannot be deleted stays, and the
  # next restart loads it again. Stopping the segment releases the mapped file and lets
  # Guardian.Storage.Schema subtract its metadata.
  defp delete_file_and_segment(table, segment_id) do
    :ok = Registration.retire_segment_id(__MODULE__, segment_id)
    filename = SegmentFile.filename(table, segment_id)

    case BlobStore.delete(filename) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.error("Could not delete #{filename}: #{inspect(reason)}")
    end
  end

  # Startup logs a line before it, since loading every file can take long enough to
  # matter (docs/architecture/system.md, section 4.4).
  defp load_all_segments_from_disk do
    {:ok, filenames} = BlobStore.list(Guardian.Storage.segment_dir())
    warn_about_unparseable_segment_files(filenames)

    filenames =
      filenames
      |> Enum.reverse()
      |> Enum.filter(&match?({:ok, _table, _segment_id}, SegmentFile.parse_filename(&1)))

    Logger.info("Storage: loading #{length(filenames)} segment files")

    Enum.each(filenames, &load_segment_file/1)
  end

  # Loads a validly named segment file. A file that cannot be loaded is logged and left
  # in place, so one bad file cannot take Storage down and the rest of the data stays
  # available.
  defp load_segment_file(filename) do
    {:ok, table, segment_id} = SegmentFile.parse_filename(filename)

    case Segment.start_supervised(load: filename, table: table, segment_id: segment_id) do
      {:ok, segment} ->
        :ok =
          Registration.register(
            @loading,
            Registration.tuple(segment_id: segment_id, segment: segment, table: table)
          )

      # Removed between listing and loading (expiry, deletion, an operator).
      {:error, {:shutdown, {:unreadable_segment, {:mmap, :enoent}}}} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Skipping unreadable segment file #{filename} " <>
            "(#{describe_size(filename)}, #{inspect(unreadable_reason(reason))}); " <>
            "the file is left in place and the rest of the data stays available"
        )
    end
  end

  defp unreadable_reason({:shutdown, {:unreadable_segment, reason}}) do
    reason
  end

  # Any other failure to start, named by its kind only: a reason can carry file bytes.
  defp unreadable_reason(reason) do
    Guardian.Failure.exit_kind(reason)
  end

  defp describe_size(filename) do
    case File.stat(filename) do
      {:ok, %File.Stat{size: size}} -> "#{size} bytes"
      {:error, reason} -> "stat failed: #{inspect(reason)}"
    end
  end

  defp warn_about_unparseable_segment_files(filenames) do
    case SegmentFile.unparseable(filenames) do
      [] ->
        :ok

      ignored ->
        Logger.warning(
          "Ignoring #{length(ignored)} .seg file(s) in #{Guardian.Storage.segment_dir()} " <>
            "that are not named {table}.{segment_id}.seg " <>
            "(for example, segments from the older per-user filename format)"
        )
    end
  end
end

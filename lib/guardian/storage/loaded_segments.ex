defmodule Guardian.Storage.LoadedSegments do
  # Internal to Storage; see lib/guardian/storage/AGENTS.md, "Public boundary".
  @moduledoc false

  alias Guardian.Storage.BlobStore
  alias Guardian.Storage.Schema
  alias Guardian.Storage.Segment
  alias Guardian.Storage.Segment.Registration
  alias Guardian.Storage.SegmentFile
  require Logger
  require Registration
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Serialized with deletion, so a file deleted while it loads cannot stay registered.
  # A slow load must not time out the persistence process. A file that won't load is
  # logged, and it's the caller's rows that are gone: nothing is reported back.
  def ensure_loaded(table, segment_id) do
    GenServer.call(__MODULE__, {:ensure_loaded, table, segment_id}, :infinity)
  end

  def segment_ids(table) do
    Registration.segment_ids(__MODULE__, table)
  end

  def get_segment(segment_id) do
    Registration.lookup(__MODULE__, segment_id)
  end

  @doc """
  Deletes a loaded segment's file and unloads it.
  """
  def delete_segment(segment_id) do
    GenServer.call(__MODULE__, {:delete_segment, segment_id})
  end

  @doc """
  Deletes a segment file and unloads it if it's loaded. Expiry uses this, since a file
  on disk isn't always loaded.
  """
  def delete_file(table, segment_id) do
    GenServer.call(__MODULE__, {:delete_file, table, segment_id})
  end

  # Files load here at startup and when PersistedSegments asks, and nowhere else.
  #
  # Loaded segments are linked to this process, which traps exits, so a crashing
  # segment is unregistered (Guardian.Storage.Schema's monitor subtracts its metadata)
  # instead of restarting every later Storage manager. Its file comes back at the next
  # restart.
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(__MODULE__, [:named_table, :ordered_set])
    load_all_segments_from_disk()
    {:ok, nil}
  end

  # Runs on shutdown and on any exit of this manager, normal or not, so no loaded
  # segment outlives it.
  def terminate(_reason, _state) do
    :ok = Registration.retire_all(__MODULE__)
  end

  def handle_call({:ensure_loaded, table, segment_id}, _from, state) do
    if get_segment(segment_id) == {:error, :not_found} do
      load_segment_file(SegmentFile.filename(table, segment_id))
    end

    {:reply, :ok, state}
  end

  def handle_call({:delete_segment, segment_id}, _, state) do
    case :ets.lookup(__MODULE__, segment_id) do
      [Registration.tuple(table: table)] -> delete_file_and_unload(table, segment_id)
      [] -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:delete_file, table, segment_id}, _, state) do
    delete_file_and_unload(table, segment_id)
    {:reply, :ok, state}
  end

  # One call, not exists-then-delete: a file removed in between must not crash the
  # manager. A file that cannot be deleted stays, and the next restart loads it again
  # (as a crash here would have left it). Stopping the segment releases the mapped file
  # and lets Guardian.Storage.Schema subtract its metadata. The segment may already be
  # dead; its EXIT then arrives later and finds no registration.
  defp delete_file_and_unload(table, segment_id) do
    filename = SegmentFile.filename(table, segment_id)

    case BlobStore.delete(filename) do
      :ok -> :ok
      {:error, :enoent} -> Logger.warning("Missing segment #{filename}")
      {:error, reason} -> Logger.error("Could not delete #{filename}: #{inspect(reason)}")
    end

    :ok = Registration.retire_segment_id(__MODULE__, segment_id)
  end

  # Matches by PID, so a late EXIT from a segment that was unloaded finds nothing. The file is still on disk
  # and no longer registered, so the next restart loads it again.
  def handle_info({:EXIT, segment, reason}, state) do
    Registration.unregister_exited(__MODULE__, segment)
    |> Enum.each(fn Registration.tuple(segment_id: segment_id, table: table) ->
      Logger.error(
        "Loaded segment #{segment_id} of table #{inspect(table)} exited " <>
          "(#{Guardian.Failure.exit_kind(reason)}); " <>
          "its rows are missing from queries until the next restart"
      )
    end)

    {:noreply, state}
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

    case Segment.load(filename) do
      # Linked by `Segment.load/1`; a crash arrives as an EXIT (handle_info).
      {:ok, segment} ->
        registration =
          Registration.tuple(
            segment_id: segment_id,
            segment: segment,
            table: table
          )

        :ets.insert(__MODULE__, registration)
        schema = Segment.schema!(segment)
        Schema.add_segment(registration, schema)

      # Removed between listing and loading (expiry, deletion, an operator).
      {:error, {:unreadable_segment, {:mmap, :enoent}}} ->
        :ok

      {:error, {:unreadable_segment, reason}} ->
        Logger.error(
          "Skipping unreadable segment file #{filename} " <>
            "(#{describe_size(filename)}, #{inspect(reason)}); " <>
            "the file is left in place and the rest of the data stays available"
        )
    end
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

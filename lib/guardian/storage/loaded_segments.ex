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

  @scan_interval 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def rescan do
    GenServer.call(__MODULE__, :rescan)
  end

  # Serialize with scans and deletion so cache eviction cannot leave an intact file
  # without a registry entry. A slow scan must not time out the persistence process.
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
  The IDs of every loaded segment.
  """
  def all_segment_ids do
    Registration.all_segment_ids(__MODULE__)
  end

  @doc """
  Deletes a segment's file and unloads it. Also deletes the file of a skipped
  (unreadable) segment with that ID.
  """
  def delete_segment(segment_id) do
    GenServer.call(__MODULE__, {:delete_segment, segment_id})
  end

  @doc """
  IDs of segment files that could not be loaded and were skipped. They stay on disk
  and expire like loaded segments. A file whose content failed is not retried until it
  changes; one that could not be opened or mapped is retried on every rescan.
  """
  def skipped_segment_ids do
    GenServer.call(__MODULE__, :skipped_segment_ids)
  end

  # `skipped` maps the ID of each segment file that failed to load to
  # `{filename, fingerprint}`. For a file whose content failed, the fingerprint is its
  # size, mtime, and inode, and loads retry it only once that changes (an operator
  # replacing it, or the persister rewriting it). A file that could not be opened or
  # mapped is retried on every load. Either way a failure is logged once, not every
  # minute.
  #
  # Loaded segments are linked to this process, which traps exits, so a crashing
  # segment is unregistered (Guardian.Storage.Schema's monitor subtracts its metadata) and the
  # next scan reloads its file, instead of restarting every later Storage manager.
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(__MODULE__, [:named_table, :ordered_set])
    state = load_all_segments_from_disk(%{skipped: %{}})
    schedule_scan()
    {:ok, state}
  end

  # Runs on shutdown and on any exit of this manager, normal or not, so no loaded
  # segment outlives it.
  def terminate(_reason, _state) do
    :ok = Registration.retire_all(__MODULE__)
  end

  def handle_call(:rescan, _from, state) do
    {:reply, :ok, scan_for_changes(state)}
  end

  def handle_call(:skipped_segment_ids, _from, state) do
    {:reply, Map.keys(state.skipped), state}
  end

  def handle_call({:ensure_loaded, table, segment_id}, _from, state) do
    case get_segment(segment_id) do
      {:ok, _segment} ->
        {:reply, :ok, state}

      {:error, :not_found} ->
        filename = SegmentFile.filename(table, segment_id)

        if BlobStore.exists(filename) do
          case load_unless_skipped(filename, segment_id, state) do
            {:ok, state} -> {:reply, :ok, state}
            {:skipped, state} -> {:reply, {:error, :unreadable}, state}
            {:not_found, state} -> {:reply, {:error, :not_found}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  def handle_call({:delete_segment, segment_id}, _, state) do
    state =
      case Map.pop(state.skipped, segment_id) do
        {nil, _skipped} ->
          state

        {{filename, _stat}, skipped} ->
          case BlobStore.delete(filename) do
            :ok -> :ok
            {:error, :enoent} -> :ok
            {:error, reason} -> Logger.error("Could not delete #{filename}: #{inspect(reason)}")
          end

          %{state | skipped: skipped}
      end

    :ets.select(__MODULE__, Registration.match_spec(segment_id: segment_id))
    |> Enum.each(fn Registration.tuple(table: table) = registration ->
      filename = SegmentFile.filename(table, segment_id)

      # One call, not exists-then-delete: a file removed in between must not crash
      # the manager. A file that cannot be deleted stays, and the next rescan loads it
      # again (as a crash here would have left it).
      case BlobStore.delete(filename) do
        :ok -> :ok
        {:error, :enoent} -> Logger.warning("Missing segment #{filename}")
        {:error, reason} -> Logger.error("Could not delete #{filename}: #{inspect(reason)}")
      end

      unload_segment(registration)
    end)

    {:reply, :ok, state}
  end

  # Unregisters a loaded segment and stops its process. Stopping it releases the
  # mapped file and lets Guardian.Storage.Schema subtract the segment's metadata. The segment
  # may already be dead; its EXIT then arrives later and finds no registration.
  defp unload_segment(registration) do
    Registration.retire(__MODULE__, registration)
  end

  # Matches by PID, so a late EXIT from a segment that was unloaded, or from an old
  # process whose ID has since been reloaded, finds nothing. The file is still on disk
  # and no longer registered, so the next scan loads it again.
  def handle_info({:EXIT, segment, reason}, state) do
    Registration.unregister_exited(__MODULE__, segment)
    |> Enum.each(fn Registration.tuple(segment_id: segment_id, table: table) ->
      Logger.error(
        "Loaded segment #{segment_id} of table #{inspect(table)} exited " <>
          "(#{Guardian.Failure.exit_kind(reason)}); " <>
          "the next scan reloads its file"
      )
    end)

    {:noreply, state}
  end

  def handle_info(:scan, state) do
    state = scan_for_changes(state)
    schedule_scan()
    {:noreply, state}
  end

  defp schedule_scan do
    Process.send_after(self(), :scan, @scan_interval)
  end

  defp load_all_segments_from_disk(state) do
    {:ok, filenames} = BlobStore.list(Guardian.Storage.segment_dir())
    warn_about_unparseable_segment_files(filenames)

    filenames
    |> Enum.reverse()
    |> Enum.filter(&match?({:ok, _table, _segment_id}, SegmentFile.parse_filename(&1)))
    |> Enum.reduce(state, fn filename, state ->
      {_result, state} = load_segment_file(filename, state)
      state
    end)
  end

  # Loads a file unless its content already failed to load and has not changed since.
  # A failure to open or map it (permissions, descriptor or memory limits) is about
  # the environment, not the content, so it is retried every time (logged once).
  defp load_unless_skipped(filename, segment_id, state) do
    case state.skipped do
      %{^segment_id => {^filename, {_size, _mtime, _inode} = stat}} ->
        if file_stat(filename) == stat do
          {:skipped, state}
        else
          load_segment_file(filename, state)
        end

      _ ->
        load_segment_file(filename, state)
    end
  end

  # Loads a validly named segment file. A file that cannot be loaded is logged,
  # left in place, and recorded in `skipped`, so one bad file cannot take Storage
  # down and the rest of the data stays available.
  defp load_segment_file(filename, state) do
    {:ok, table, segment_id} = SegmentFile.parse_filename(filename)
    timestamp = Guardian.SegmentID.timestamp(segment_id)

    # A retried skipped file was announced already; its failure is logged once below.
    unless Map.has_key?(state.skipped, segment_id) do
      IO.puts("Loading #{filename} from #{timestamp}")
    end

    stat = file_stat(filename)

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
        {:ok, %{state | skipped: Map.delete(state.skipped, segment_id)}}

      # Removed between listing and loading (expiry, deletion, an operator).
      {:error, {:unreadable_segment, {:mmap, :enoent}}} ->
        {:not_found, %{state | skipped: Map.delete(state.skipped, segment_id)}}

      # `stat` was taken before the attempt; if the file changed during it (an
      # operator renaming a replacement into place), the replacement was never tried,
      # so the entry is retried rather than remembered as bad.
      {:error, {:unreadable_segment, reason}} ->
        fingerprint =
          if file_stat(filename) == stat, do: fingerprint(reason, stat), else: {:retry, reason}

        unless Map.get(state.skipped, segment_id) == {filename, fingerprint} do
          Logger.error(
            "Skipping unreadable segment file #{filename} " <>
              "(#{describe_stat(stat)}, #{inspect(reason)}); " <>
              "the file is left in place and the rest of the data stays available"
          )
        end

        skipped = Map.put(state.skipped, segment_id, {filename, fingerprint})
        {:skipped, %{state | skipped: skipped}}
    end
  end

  # What a skipped entry remembers: the file's size, mtime, and inode for a content
  # failure, or the failure itself for one that is retried every time.
  defp fingerprint({:mmap, _posix} = reason, _stat) do
    {:retry, reason}
  end

  defp fingerprint(reason, {:error, _} = _stat) do
    {:retry, reason}
  end

  defp fingerprint(_reason, stat) do
    stat
  end

  defp file_stat(filename) do
    case File.stat(filename) do
      {:ok, %File.Stat{size: size, mtime: mtime, inode: inode}} -> {size, mtime, inode}
      {:error, reason} -> {:error, reason}
    end
  end

  defp describe_stat({size, _mtime, _inode}) do
    "#{size} bytes"
  end

  defp describe_stat({:error, reason}) do
    "stat failed: #{inspect(reason)}"
  end

  defp warn_about_unparseable_segment_files(filenames) do
    case SegmentFile.unparseable(filenames) do
      [] ->
        :ok

      ignored ->
        IO.puts(
          "Ignoring #{length(ignored)} .seg file(s) in #{Guardian.Storage.segment_dir()} " <>
            "that are not named {table}.{segment_id}.seg " <>
            "(for example, segments from the older per-user filename format)"
        )
    end
  end

  defp scan_for_changes(state) do
    {:ok, filenames} = BlobStore.list(Guardian.Storage.segment_dir())

    # Build map from segment_id -> filename for files on disk
    disk_segments =
      filenames
      |> Enum.flat_map(fn filename ->
        case SegmentFile.parse_filename(filename) do
          {:ok, _table, segment_id} -> [{segment_id, filename}]
          :error -> []
        end
      end)
      |> Map.new()

    disk_segment_ids = Map.keys(disk_segments) |> MapSet.new()

    # Get segment_ids from ETS
    ets_segment_ids = all_segment_ids() |> MapSet.new()

    # Find new segments (on disk but not in ETS)
    new_segment_ids = MapSet.difference(disk_segment_ids, ets_segment_ids)

    # Find removed segments (in ETS but not on disk)
    removed_segment_ids = MapSet.difference(ets_segment_ids, disk_segment_ids)

    # Forget skipped files that are gone
    state = %{state | skipped: Map.take(state.skipped, Map.keys(disk_segments))}

    # Load new segments, skipping files that already failed and have not changed
    state =
      Enum.reduce(new_segment_ids, state, fn segment_id, state ->
        filename = Map.fetch!(disk_segments, segment_id)
        {_result, state} = load_unless_skipped(filename, segment_id, state)
        state
      end)

    # Stop and remove segments whose files no longer exist
    for segment_id <- removed_segment_ids do
      case :ets.lookup(__MODULE__, segment_id) do
        [registration] -> unload_segment(registration)
        [] -> :ok
      end
    end

    state
  end
end

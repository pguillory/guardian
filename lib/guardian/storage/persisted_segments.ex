defmodule Guardian.Storage.PersistedSegments do
  # Internal to Storage; see lib/guardian/storage/AGENTS.md, "Public boundary".
  @moduledoc false

  alias Guardian.Storage.FullSegments
  alias Guardian.Storage.LoadedSegments
  alias Guardian.Storage.Segment
  alias Guardian.Storage.Segment.Registration
  alias Guardian.Storage.SegmentFile
  require Registration
  use GenServer
  require Logger

  # How long a persisted segment stays cached in memory after it is written, by
  # default. Configurable (`:guardian, :persisted_segment_cache_ms`) so tests and
  # measurements can shorten it.
  @default_cache_ms 600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ping do
    GenServer.cast(__MODULE__, :ping)
  end

  def segment_ids(table) do
    Registration.segment_ids(__MODULE__, table)
  end

  def get_segment(segment_id) do
    Registration.lookup(__MODULE__, segment_id)
  end

  def delete_segment(segment_id) do
    GenServer.call(__MODULE__, {:delete_segment, segment_id})
  end

  def init(_opts) do
    cache_ms = cache_ms()

    # Checked at startup, as MutableSegments checks its maximum age; the window is read
    # again each time it is used, so tests can shorten it.
    unless is_integer(cache_ms) and cache_ms > 0 do
      raise ArgumentError, "persisted_segment_cache_ms must be a positive integer"
    end

    Process.flag(:trap_exit, true)
    :ets.new(__MODULE__, [:named_table])
    # Segments whose store failed and was logged; retried every pass, logged once.
    state = %{unstorable: MapSet.new()}
    Process.send_after(self(), :ping, 1000)
    {:ok, state}
  end

  # Runs on shutdown and on any exit of this manager: persist what FullSegments still
  # holds, then stop the cached segments, whose rows are on disk.
  def terminate(_reason, state) do
    persist_segments(state)

    :ok = Registration.retire_all(__MODULE__)
  end

  def handle_cast(:ping, state) do
    {:noreply, persist_segments(state)}
  end

  def handle_info(:ping, state) do
    state = persist_segments(state)
    Process.send_after(self(), :ping, 1000)
    {:noreply, state}
  end

  # Loads the file just written, from a message rather than in the persist pass, which
  # `terminate` also runs: LoadedSegments may be gone by then. A segment already deleted
  # stays unloaded. A file that won't load is logged by LoadedSegments; the in-memory
  # copy serves until its time is up, and then those rows are gone.
  def handle_info({:load, registration}, state) do
    Registration.tuple(segment_id: segment_id, table: table) = registration

    if :ets.lookup(__MODULE__, segment_id) == [registration] do
      :ok = LoadedSegments.ensure_loaded(table, segment_id)
    end

    {:noreply, state}
  end

  # Stops the in-memory copy and frees its memory. Lookups check Loaded first, so normally
  # no read holds its PID. Calls already queued are answered first; a read that resolved
  # this PID before the file was registered and calls it later gets segment_unavailable.
  def handle_info({:delete, registration}, state) do
    Registration.tuple(segment_id: segment_id) = registration

    if :ets.lookup(__MODULE__, segment_id) == [registration] do
      :ok = Registration.retire(__MODULE__, registration)
    end

    {:noreply, state}
  end

  # Cached segments are linked to this process, which traps exits. Matches by PID: a
  # late EXIT from a segment that was evicted, deleted, or retired finds nothing. A
  # cached segment's rows are on disk and normally already loaded from there. If that
  # load failed or hadn't run yet, they're missing from queries until the next restart.
  def handle_info({:EXIT, segment, reason}, state) do
    Registration.unregister_exited(__MODULE__, segment)
    |> Enum.each(fn Registration.tuple(segment_id: segment_id, table: table) ->
      unless Segment.normal_exit?(reason) do
        Logger.error(
          "Persisted segment #{segment_id} of table #{inspect(table)} exited " <>
            "(#{Guardian.Failure.exit_kind(reason)}); its rows are served from its file if it loaded"
        )
      end
    end)

    {:noreply, state}
  end

  defp cache_ms do
    Application.get_env(:guardian, :persisted_segment_cache_ms, @default_cache_ms)
  end

  def handle_call({:delete_segment, segment_id}, _, state) do
    :ok = Registration.retire_segment_id(__MODULE__, segment_id)
    {:reply, :ok, state}
  end

  defp persist_segments(state) do
    Enum.reduce(FullSegments.registrations(), state, &persist_segment/2)
  end

  defp persist_segment(
         Registration.tuple(segment_id: segment_id, segment: segment, table: table) =
           registration,
         state
       ) do
    try do
      :ok = Segment.pack(segment)
    catch
      # The segment is stuck or slow past the call timeout: still alive, so it is
      # retried on the next pass (GenServer.call drops its late reply), but its rows
      # stay only in memory meanwhile, so it is logged once like a failed write.
      :exit, {:timeout, {GenServer, :call, _}} ->
        unstorable(state, segment_id, table, {:pack, :timeout})

      # The segment died (deleted, or crashed, which its own crash report logs).
      # FullSegments unregisters it when its EXIT arrives.
      :exit, _reason ->
        state
    else
      _ ->
        filename = SegmentFile.filename(table, segment_id)

        case store(segment, filename) do
          :ok ->
            true = :ets.insert(__MODULE__, registration)
            true = Process.link(segment)
            :ok = FullSegments.delete(registration)

            send(self(), {:load, registration})
            Process.send_after(self(), {:delete, registration}, cache_ms())
            %{state | unstorable: MapSet.delete(state.unstorable, segment_id)}

          {:error, reason} ->
            unstorable(state, segment_id, table, reason)
        end
    end
  end

  # A segment that cannot be written (a full disk, a filename the filesystem rejects)
  # stays in FullSegments, still queryable, and is retried on every pass; it must not
  # crash the persister, which would stall every segment queued behind it.
  defp store(segment, filename) do
    case Segment.store(segment, filename) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  rescue
    exception -> {:error, exception.__struct__}
  catch
    # Only the exit's kind: a segment that crashed mid-call exits with a reason that
    # can carry its rows, and this error is logged.
    :exit, reason -> {:error, {:exit, Guardian.Failure.exit_kind(reason)}}
  end

  defp unstorable(state, segment_id, table, reason) do
    if MapSet.member?(state.unstorable, segment_id) do
      state
    else
      Logger.error(
        "Could not persist segment #{segment_id} of table #{inspect(table)}: " <>
          "#{inspect(reason, limit: 10, printable_limit: 200)}; it stays in memory and is retried"
      )

      %{state | unstorable: MapSet.put(state.unstorable, segment_id)}
    end
  end
end

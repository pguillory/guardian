defmodule Guardian.Storage.FullSegments do
  # Internal to Storage; see lib/guardian/storage/CLAUDE.md, "Public boundary".
  @moduledoc false

  alias Guardian.Storage.Segment
  alias Guardian.Storage.Segment.Registration
  require Logger
  require Registration
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def insert(registration) do
    GenServer.call(__MODULE__, {:insert, registration})
  end

  def delete(registration) do
    GenServer.call(__MODULE__, {:delete, registration})
  end

  def registrations do
    :ets.tab2list(__MODULE__)
  end

  def segment_ids(table), do: Registration.segment_ids(__MODULE__, table)

  def get_segment(segment_id), do: Registration.lookup(__MODULE__, segment_id)

  def delete_segment(segment_id) do
    GenServer.call(__MODULE__, {:delete_segment, segment_id})
  end

  # Full segments are linked to this process, which traps exits, so a crashing segment
  # loses only its own rows instead of taking this manager (and, through
  # `:rest_for_one`, every later manager's segments) down with it.
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(__MODULE__, [:named_table])
    state = %{}
    {:ok, state}
  end

  # Runs on shutdown and on any exit of this manager. MutableSegments and
  # PersistedSegments stop first, so whatever is left was never persisted.
  def terminate(_reason, _state) do
    :ok = Registration.retire_all(__MODULE__)
  end

  def handle_call({:insert, registration}, _, state) do
    true = :ets.insert(__MODULE__, registration)
    segment = Registration.segment(registration)
    true = Process.link(segment)
    {:reply, :ok, state}
  end

  def handle_call({:delete, registration}, _, state) do
    true = :ets.delete_object(__MODULE__, registration)
    segment = Registration.segment(registration)
    true = Process.unlink(segment)
    {:reply, :ok, state}
  end

  def handle_call({:delete_segment, segment_id}, _, state) do
    :ok = Registration.retire_segment_id(__MODULE__, segment_id)
    {:reply, :ok, state}
  end

  # Matches by PID: a late EXIT from a segment this manager no longer holds (deleted,
  # retired, or handed to PersistedSegments) finds nothing and is ignored.
  def handle_info({:EXIT, segment, reason}, state) do
    Registration.unregister_exited(__MODULE__, segment)
    |> Enum.each(fn Registration.tuple(segment_id: segment_id, table: table) ->
      # PersistedSegments registers a segment it has written before it releases it
      # here, so a segment that dies in between is on disk after all.
      Logger.error(
        "Full segment #{segment_id} of table #{inspect(table)} exited " <>
          "(#{Segment.exit_kind(reason)}); its rows are lost unless it was just persisted"
      )
    end)

    {:noreply, state}
  end
end

defmodule Web.IngestIdempotency do
  @moduledoc """
  Short-lived, node-local receipts for client-keyed ingest batches.

  The coordinator holds metadata only; the caller runs ingestion. Capacity,
  restarts and unavailability can lose protection, never prevent ingestion.
  """

  use GenServer
  require Logger

  @retention_ms 10_000
  @max_entries 10_000
  @call_timeout 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `ingest` once for a new key, or returns a compact receipt/conflict.
  `request` is the validated `{events, return_keys}`, used only to compute a digest.
  """
  def run(table, key, request, ingest, server \\ __MODULE__) do
    digest = :crypto.hash(:sha256, :erlang.term_to_iovec(request, [:deterministic]))
    token = make_ref()
    pid = GenServer.whereis(server)

    case call(pid, {:claim, {table, key}, digest, token}) do
      :claimed ->
        ingest_claimed(pid, token, ingest)

      {:done, failed_events} ->
        {:ok, %{status: 200, duplicate: true, failed_events: failed_events}}

      :conflict ->
        {:error, 409, "idempotency_key was already used with different events or return_keys"}

      :pending ->
        {:error, 409, "idempotency_key is still in flight; retry the same request promptly"}

      :uncertain ->
        {:error, 409, "idempotency_key outcome is unknown; events may have been stored"}

      reason when reason in [:full, :unavailable] ->
        # A timed-out call may still claim later. Signals from this caller to this
        # exact pid are ordered, so cancellation follows even a late claim. Never
        # send it to the registered name, which may now name a restarted server.
        if pid, do: GenServer.cast(pid, {:cancel, token, self()})
        Logger.info("Ingest idempotency protection unavailable; ingesting without a receipt")
        {:ok, ingest.()}
    end
  end

  defp ingest_claimed(pid, token, ingest) do
    result =
      try do
        ingest.()
      catch
        kind, reason ->
          _ = call(pid, {:finish, token, :uncertain})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    failed_events = Enum.count(result.results, &(!&1.success))
    _ = call(pid, {:finish, token, {:done, failed_events}})
    {:ok, result}
  end

  defp call(nil, _message), do: :unavailable

  defp call(pid, message) do
    GenServer.call(pid, message, @call_timeout)
  catch
    :exit, _reason -> :unavailable
  end

  @impl true
  def init(opts) do
    state = %{
      entries: %{},
      claims: %{},
      monitors: %{},
      completed: :gb_trees.empty(),
      retention_ms: Keyword.get(opts, :retention_ms, @retention_ms),
      max_entries: Keyword.get(opts, :max_entries, @max_entries),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
    }

    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_call({:claim, identity, digest, token}, {owner, _tag}, state) do
    state = expire(state)

    case Map.get(state.entries, identity) do
      nil ->
        state = make_room(state)

        if map_size(state.entries) < state.max_entries do
          # Jason may return sub-binaries backed by the entire request body. Keep
          # only bounded, independent copies of these two strings.
          {table, key} = identity
          identity = {:binary.copy(table), :binary.copy(key)}
          monitor = Process.monitor(owner)

          entry = %{
            digest: digest,
            status: :pending,
            owner: owner,
            token: token,
            monitor: monitor,
          }

          state = %{
            state
            | entries: Map.put(state.entries, identity, entry),
              claims: Map.put(state.claims, token, identity),
              monitors: Map.put(state.monitors, monitor, token),
          }

          {:reply, :claimed, state}
        else
          {:reply, :full, state}
        end

      %{digest: other} when other != digest ->
        {:reply, :conflict, state}

      %{status: status} ->
        {:reply, status, state}
    end
  end

  def handle_call({:finish, token, status}, {owner, _tag}, state) do
    {:reply, :ok, finish(state, token, owner, status)}
  end

  @impl true
  def handle_cast({:cancel, token, owner}, state) do
    state =
      case pending(state, token, owner) do
        nil -> state
        {identity, entry} -> drop_pending(state, identity, entry)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    state =
      case Map.get(state.monitors, monitor) do
        nil -> state
        token -> finish(state, token, owner, :uncertain)
      end

    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    schedule_sweep()
    {:noreply, expire(state)}
  end

  # No keys, digests, caller messages or past states in formatted status/reports.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, %{entries: map_size(state.entries)}}
      {:log, _value} -> {:log, []}
      {field, _value} -> {field, :redacted}
    end)
  end

  defp pending(state, token, owner) do
    with {:ok, identity} <- Map.fetch(state.claims, token) do
      case state.entries[identity] do
        %{token: ^token, owner: ^owner} = entry -> {identity, entry}
        _entry -> nil
      end
    else
      :error -> nil
    end
  end

  defp finish(state, token, owner, status) do
    case pending(state, token, owner) do
      nil ->
        state

      {identity, entry} ->
        state = drop_pending(state, identity, entry)
        expires = {state.clock.() + state.retention_ms, token}
        completed = %{digest: entry.digest, status: status}

        %{
          state
          | entries: Map.put(state.entries, identity, completed),
            completed: :gb_trees.insert(expires, identity, state.completed),
        }
    end
  end

  defp drop_pending(state, identity, entry) do
    Process.demonitor(entry.monitor, [:flush])

    %{
      state
      | entries: Map.delete(state.entries, identity),
        claims: Map.delete(state.claims, entry.token),
        monitors: Map.delete(state.monitors, entry.monitor),
    }
  end

  defp expire(state) do
    if :gb_trees.is_empty(state.completed) do
      state
    else
      {{expires, _token}, _identity} = :gb_trees.smallest(state.completed)
      if expires <= state.clock.(), do: state |> evict_oldest() |> expire(), else: state
    end
  end

  defp make_room(state) do
    if map_size(state.entries) >= state.max_entries and not :gb_trees.is_empty(state.completed),
      do: evict_oldest(state),
      else: state
  end

  defp evict_oldest(state) do
    {_expires, identity, completed} = :gb_trees.take_smallest(state.completed)
    %{state | entries: Map.delete(state.entries, identity), completed: completed}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, 1_000)
end

defmodule Guardian.Test.Counters.StorePause do
  @moduledoc """
  Pauses a real `Guardian.Counters.Store`'s callers, and owns the test side's knowledge
  of the Store's private descriptor (its `:counter_store_descriptor` process-dictionary
  key). `store?/1` tells a real Store from a probe for
  `Guardian.Test.Counters.ProbeStore.backend/1`.

  A pause is a suspended gate process recorded in the store's own ETS table (a 2-tuple
  row, which Store's operations and housekeeping never match, and which dies with the
  store). `Guardian.Test.Counters.Backend` calls the gate before handing a batch to the
  Store, so Transport callers (local, or on a peer through the remote endpoint) queue
  on the gate. The gate runs before Store's own deadline checks: a caller whose
  deadline passed while paused gets `{:error, :timeout}` without mutating. Direct
  Store calls bypass the gate.
  """
  use GenServer

  @descriptor :counter_store_descriptor
  @gate {__MODULE__, :gate}

  # Pause actual callers, not the housekeeping process. Tests can still await a
  # queued call on this gate and release its reply through ordinary sys controls.
  def pause(store) do
    {:ok, gate} = GenServer.start(__MODULE__, :gate)
    :ok = :sys.suspend(gate)
    table = table(store)
    :ets.insert(table, {@gate, gate})
    {gate, table}
  end

  def resume({gate, table}) do
    :ets.delete(table, @gate)
    :sys.resume(gate)
    GenServer.stop(gate)
    :ok
  end

  @doc """
  Waits on `server`'s gate, if it is paused. `server` is a Store option value (a
  registered name, PID or table reference); anything else is never paused.
  """
  def await_gate(server) do
    case gate(server) do
      nil -> :ok
      gate -> GenServer.call(gate, :pass, :infinity)
    end
  end

  @doc "Whether `pid` is a real Store, which publishes its descriptor in its dictionary."
  def store?(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.has_key?(dictionary, @descriptor)
    end
  end

  defp gate(server) do
    table =
      cond do
        is_atom(server) -> :ets.whereis(server)
        is_reference(server) -> server
        is_pid(server) -> table(server)
        true -> :undefined
      end

    case :ets.lookup(table, @gate) do
      [{@gate, gate}] -> gate
      [] -> nil
    end
  catch
    _, _ -> nil
  end

  defp table(store) do
    pid = if is_pid(store), do: store, else: Process.whereis(store)

    {{:dictionary, @descriptor}, table} =
      :erlang.process_info(pid, {:dictionary, @descriptor})

    table
  end

  @impl true
  def init(:gate) do
    {:ok, :gate}
  end

  @impl true
  def handle_call(:pass, _, state) do
    {:reply, :ok, state}
  end
end

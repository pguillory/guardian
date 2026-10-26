defmodule Guardian.Test.Counters.StorePause do
  @moduledoc """
  Pauses a real `Guardian.Counters.Store`'s callers through its clock, and owns the
  test side's knowledge of the Store's private descriptor (the
  `:counter_store_descriptor` process-dictionary key and ETS row). `store?/1` tells a
  real Store from a probe for `Guardian.Test.Counters.ProbeStore.backend/1`.
  """
  use GenServer

  # Pause actual callers, not the housekeeping process. Tests can still await a
  # queued call on this gate and release its reply through ordinary sys controls.
  def pause(store) do
    {:ok, gate} = GenServer.start(__MODULE__, :gate)
    :ok = :sys.suspend(gate)
    {table, descriptor} = descriptor(store)

    clock = fn ->
      GenServer.call(gate, :clock, :infinity)
      descriptor.clock.()
    end

    :ets.insert(table, {:counter_store_descriptor, %{descriptor | clock: clock}})
    {gate, table, descriptor}
  end

  def resume({gate, table, descriptor}) do
    :ets.insert(table, {:counter_store_descriptor, descriptor})
    :sys.resume(gate)
    GenServer.stop(gate)
    :ok
  end

  @doc "Whether `pid` is a real Store, which publishes its descriptor in its dictionary."
  def store?(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.has_key?(dictionary, :counter_store_descriptor)
    end
  end

  defp descriptor(store) do
    pid = if is_pid(store), do: store, else: Process.whereis(store)

    {{:dictionary, :counter_store_descriptor}, table} =
      :erlang.process_info(pid, {:dictionary, :counter_store_descriptor})

    [{:counter_store_descriptor, descriptor}] = :ets.lookup(table, :counter_store_descriptor)
    {table, descriptor}
  end

  @impl true
  def init(:gate) do
    {:ok, :gate}
  end

  @impl true
  def handle_call(:clock, _, state) do
    {:reply, :ok, state}
  end
end

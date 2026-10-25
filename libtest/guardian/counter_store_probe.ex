defmodule Guardian.CounterStoreProbe do
  @moduledoc false
  use GenServer

  # Mailbox transport doubles stay outside the production ETS Store.
  def batch(operations, opts) do
    request({:batch, operations}, opts)
  end

  defp request(operation, opts) do
    GenServer.call(opts[:server], {:operation, opts[:deadline], operation}, opts[:timeout])
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    _, _ -> {:error, :unavailable}
  end

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

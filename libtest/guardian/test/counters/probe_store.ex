defmodule Guardian.Test.Counters.ProbeStore do
  @moduledoc """
  A scripted counter store for transport-level tests, reached through the libtest
  batch adapter (`Guardian.CounterStoreProbe`). Started with `fun`, it answers each
  operation of a batch with `fun.(operation)`; started with `{:pipeline, fun}`, it
  answers a whole batch with `fun.(operations)`.

  `backend/1` turns a store into the Context `:store` option: a registered name or a
  real `Guardian.Counters.Store` stays as is, and any other process (a probe) goes
  through the adapter.
  """
  use GenServer

  def start_link(handler) do
    GenServer.start_link(__MODULE__, handler)
  end

  @impl true
  def init(handler) do
    {:ok, handler}
  end

  @impl true
  def handle_call(
        {:operation, _deadline, {:batch, operations}},
        _from,
        {:pipeline, handler} = state
      ) do
    {:reply, handler.(operations), state}
  end

  def handle_call({:operation, _deadline, {:batch, operations}}, _from, handler) do
    {:reply, {:ok, Enum.map(operations, handler)}, handler}
  end

  def backend(store) when is_atom(store) do
    store
  end

  def backend(store) do
    case Process.info(store, :dictionary) do
      {:dictionary, dictionary} ->
        if Keyword.has_key?(dictionary, :counter_store_descriptor),
          do: store,
          else: {Guardian.CounterStoreProbe, store}
    end
  end
end

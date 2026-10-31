defmodule Guardian.Test.Counters.ProbeStore do
  @moduledoc """
  A scripted counter store for transport-level tests. Started with `fun`, it answers
  each operation of a batch with `fun.(operation)`; started with `{:pipeline, fun}`,
  it answers a whole batch with `fun.(operations)`.

  `batch/3` is also the mailbox batch adapter that `Guardian.Test.Counters.Backend`
  calls for a `{Guardian.Test.Counters.ProbeStore, server}` store option, for this
  probe or any other process speaking its `{:operation, deadline, {:batch, ops}}`
  call. Mailbox transport doubles
  stay outside the production ETS Store.

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

  # Probes script their own answers, so they ignore `now`.
  def batch(operations, _now, opts) do
    request({:batch, operations}, opts)
  end

  defp request(operation, opts) do
    GenServer.call(opts[:server], {:operation, opts[:deadline], operation}, opts[:timeout])
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    _, _ -> {:error, :unavailable}
  end

  def backend(store) when is_atom(store) do
    store
  end

  def backend(store) do
    if store?(store), do: store, else: {__MODULE__, store}
  end

  # A real Store publishes its descriptor in its process dictionary.
  defp store?(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.has_key?(dictionary, :counter_store_descriptor)
    end
  end
end

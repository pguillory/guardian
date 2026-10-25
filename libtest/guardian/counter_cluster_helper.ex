defmodule Guardian.CounterClusterHelper do
  @moduledoc false

  def start_store(opts \\ []) do
    Code.ensure_loaded!(Guardian.Counters.Cluster)
    caller = self()

    spawn(fn ->
      send(caller, {:counter_store_started, Guardian.Counters.Store.start_link(opts)})
      Process.sleep(:infinity)
    end)

    receive do
      {:counter_store_started, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end
end

defmodule Guardian.CounterPipelineProbe do
  @moduledoc false
  use GenServer

  def start_link(observer) do
    GenServer.start_link(__MODULE__, observer, name: __MODULE__)
  end

  def start(observer) do
    caller = self()

    spawn(fn ->
      send(caller, {:probe_started, GenServer.start_link(__MODULE__, observer, name: __MODULE__)})
      Process.sleep(:infinity)
    end)

    receive do
      {:probe_started, result} -> result
    end
  end

  def init(observer) do
    {:ok, observer}
  end

  def handle_call({:operation, _deadline, {:batch, ops}}, _from, observer) do
    send(observer, {:pipeline, node(), self(), ops})

    receive do
      :release ->
        results =
          Enum.map(ops, fn
            {:get, {_, _, bucket}} -> {:ok, bucket}
            _ -> {:ok, 1}
          end)

        {:reply, {:ok, results}, observer}
    end
  end

  def handle_info(:release, observer) do
    {:noreply, observer}
  end
end

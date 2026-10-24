defmodule CounterClusterHelper do
  @moduledoc false

  def start_store(opts \\ []) do
    Code.ensure_loaded!(Counters.Cluster)
    caller = self()

    spawn(fn ->
      send(caller, {:counter_store_started, Counters.Store.start_link(opts)})
      Process.sleep(:infinity)
    end)

    receive do
      {:counter_store_started, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end
end

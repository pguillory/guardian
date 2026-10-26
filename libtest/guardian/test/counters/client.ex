defmodule Guardian.Test.Counters.Client do
  @moduledoc """
  Starts and warms counter stores for peer tests. Tests using connected peers or
  shared named stores require `async: false`; callers own the peer lifecycle.
  """

  @doc """
  Loads the counter endpoint's call path and test doubles on this node. Peers load
  code lazily, so call it on a fresh peer (over `:erpc`) before any budgeted call.
  """
  def preload do
    for module <- [
          Guardian.Counters.Clock,
          Guardian.Counters.Context,
          Guardian.Counters.Transport,
          Guardian.Counters.Store,
          Guardian.CounterTestBackend,
          Guardian.CounterStoreProbe,
        ],
        do: Code.ensure_loaded!(module)

    :ok
  end

  def start_store(opts \\ []) do
    preload()
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

  @ready_ms 20
  @ready_rounds 3
  @ready_wait_ms 10_000

  @doc """
  Readiness barrier for freshly started peer stores. A new peer loads code lazily
  and is still finishing its boot, so its first counter pipelines can exceed the
  production 50 ms call budget under host load. This waits until each node answers
  #{@ready_rounds} consecutive real owner pipelines (a get on a key no test uses)
  with `{:ok, [:not_found]}` within #{@ready_ms} ms, and raises once
  #{@ready_wait_ms} ms have passed for the whole set. It calls the remote endpoint
  directly, so it never touches cooldown tables or batch budgets. It warms only the
  peer side, and fast replies now do not guarantee fast replies under later load.
  """
  def await_ready(nodes, store \\ Guardian.Counters.Store) do
    deadline = System.monotonic_time(:millisecond) + @ready_wait_ms
    Enum.each(List.wrap(nodes), &await_node(&1, store, deadline, 0))
  end

  defp await_node(_node, _store, _deadline, @ready_rounds) do
    :ok
  end

  defp await_node(node, store, deadline, rounds) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      raise "#{node} did not answer counter pipelines within #{@ready_ms} ms " <>
              "in #{@ready_wait_ms} ms"
    end

    key = {{"readiness", "#{System.unique_integer([:positive])}", "probe"}, {}, 0}
    args = [{:batch, [{:get, key}]}, store, Guardian.Counters.Context.operation_ms()]
    started = System.monotonic_time(:microsecond)

    result =
      try do
        :erpc.call(node, Guardian.Counters.Transport, :remote_operation, args, remaining)
      catch
        _, _ -> :error
      end

    elapsed_us = System.monotonic_time(:microsecond) - started

    if result == {:ok, [:not_found]} and elapsed_us <= @ready_ms * 1_000 do
      await_node(node, store, deadline, rounds + 1)
    else
      Process.sleep(10)
      await_node(node, store, deadline, 0)
    end
  end
end

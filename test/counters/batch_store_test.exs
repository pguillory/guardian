defmodule Counters.BatchStoreTest do
  use ExUnit.Case, async: true
  alias Counters.Store

  test "a pipeline preserves operation order, missing versus nil, conflicts and malformed replies" do
    store = start_supervised!({Store, name: nil})

    assert Store.batch(
             [
               {:get, :k},
               {:cas, :k, :missing, nil, 5_000},
               {:get, :k},
               {:incr, :k, 1, 5_000},
               {:cas, :k, :missing, 3, 5_000},
               :bad,
             ],
             server: store
           ) ==
             {:ok,
              [
                :not_found,
                :ok,
                {:ok, nil},
                {:error, :not_integer},
                {:error, :conflict},
                {:error, :invalid_request},
              ]}

    assert Store.batch(List.duplicate({:get, :k}, 4_001), server: store) ==
             {:error, :invalid_request}

    assert Store.batch([], server: store) == {:ok, []}
  end

  test "the deadline is checked between operations and skips queued writes" do
    parent = self()

    clock = fn ->
      send(parent, {:clock, self()})

      receive do
        :release -> System.monotonic_time(:millisecond)
      end
    end

    store = start_supervised!({Store, name: nil, clock: clock, sweep_interval_ms: 60_000})
    deadline = System.monotonic_time(:millisecond) + 1_000

    task =
      Task.async(fn ->
        GenServer.call(
          store,
          {:operation, deadline,
           {:batch, [{:incr, :first, 1, 5_000}, {:incr, :second, 1, 5_000}]}},
          5_000
        )
      end)

    assert_receive {:clock, ^store}
    Process.sleep(max(0, deadline - System.monotonic_time(:millisecond) + 1))
    send(store, :release)
    assert Task.await(task) == {:ok, [{:ok, 1}, {:error, :timeout}]}
    refute_receive {:clock, _}, 10
  end
end

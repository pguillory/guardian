defmodule Guardian.Counters.BatchStoreTest do
  use ExUnit.Case, async: true
  alias Guardian.Counters.Store

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
    calls = :atomics.new(1, [])

    clock = fn ->
      if :atomics.add_get(calls, 1, 1) == 2 do
        send(parent, {:clock, self()})

        receive do
          :release -> :ok
        end
      end

      System.monotonic_time(:millisecond)
    end

    store = start_supervised!({Store, name: nil, clock: clock, sweep_interval_ms: 60_000})
    deadline = System.monotonic_time(:millisecond) + 1_000

    task =
      Task.async(fn ->
        Store.batch(
          [{:incr, :first, 1, 5000}, {:incr, :second, 1, 5000}, {:incr, :third, 1, 5000}],
          server: store,
          deadline: deadline,
          timeout: 5000
        )
      end)

    assert_receive {:clock, caller}
    Process.sleep(max(0, deadline - System.monotonic_time(:millisecond) + 1))
    send(caller, :release)
    assert Task.await(task) == {:ok, [{:ok, 1}, {:error, :timeout}, {:error, :timeout}]}
    assert :atomics.get(calls, 1) == 2
    assert Store.get(:first, server: store) == {:ok, 1}
    assert Store.get(:second, server: store) == :not_found
    assert Store.get(:third, server: store) == :not_found
  end
end

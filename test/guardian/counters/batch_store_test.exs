defmodule Guardian.Counters.BatchStoreTest do
  use ExUnit.Case, async: true
  alias Guardian.Counters.Store

  test "a pipeline preserves operation order, missing versus nil, lost adds and malformed replies" do
    store = start_supervised!({Store, name: nil})

    assert Store.batch(
             [
               {:get, :k},
               {:add, :k, nil, 5_000},
               {:get, :k},
               {:incr, :k, 1, 5_000},
               {:add, :k, 3, 5_000},
               :bad,
             ],
             System.monotonic_time(:millisecond),
             server: store
           ) ==
             {:ok,
              [
                :not_found,
                :ok,
                {:ok, nil},
                {:error, :not_integer},
                {:error, :not_stored},
                {:error, :invalid_request},
              ]}

    now = System.monotonic_time(:millisecond)

    assert Store.batch(List.duplicate({:get, :k}, 4_001), now, server: store) ==
             {:error, :invalid_request}

    assert Store.batch([], now, server: store) == {:ok, []}
  end

  test "the deadline is checked between operations and skips queued writes" do
    store = start_supervised!({Store, name: nil, sweep_interval_ms: 3_600_000})
    now = System.monotonic_time(:millisecond)
    # Each key takes a while to encode, so 4,000 of them outlast a 20 ms deadline on
    # any machine. Where the deadline falls depends on the host; the shape doesn't.
    big = Enum.to_list(1..100_000)
    operations = for i <- 1..4_000, do: {:incr, {i, big}, 1, 60_000}

    case Store.batch(operations, now, server: store, deadline: now + 20, timeout: 5_000) do
      {:ok, results} ->
        {done, skipped} = Enum.split_while(results, &match?({:ok, 1}, &1))
        assert skipped != []
        assert Enum.all?(skipped, &(&1 == {:error, :timeout}))
        assert {:ok, %{keys: keys}} = Store.stats(server: store)
        assert keys == length(done)

      # A host stall past the deadline before the first operation times out the request.
      {:error, :timeout} ->
        assert {:ok, %{keys: 0}} = Store.stats(server: store)
    end
  end
end

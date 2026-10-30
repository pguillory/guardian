defmodule Guardian.Counters.BudgetTest do
  use ExUnit.Case, async: true
  import Guardian.Counters.Budget
  alias Guardian.Counters.Budget
  alias Guardian.Counters.Client

  setup do
    start_supervised!({Budget, name: :counter_budget_test})

    # A long event budget, so however late a test reserves under load, the reservation
    # is exactly the default 50 ms call budget.
    event =
      Client.new_event(Client.new_batch(),
        cooldown_table: :counter_budget_test,
        event_timeout_ms: 10_000
      )

    %{event: event}
  end

  test "healthy responses refund fully without inspecting stored values", %{event: event} do
    responses = [
      :ok,
      :not_found,
      {:error, :exists},
      {:error, :not_stored},
      {:ok, [{:error, :unavailable}, {:error, :timeout}]},
      {:ok, [{:error, :timeout}], :opaque_token},
    ]

    assert {:ok, started, reserved} = reserve(event, node())
    settle({:ok, responses}, node(), event, started, reserved, started + 40_000)
    assert :atomics.get(event.batch, 1) == 250_000
    assert :ets.tab2list(:counter_budget_test) == []
  end

  test "mixed failures charge one completion wait, bounded by the reservation", %{event: event} do
    for {elapsed, charged} <- [{12_000, 12_000}, {80_000, 50_000}] do
      fresh = %{event | batch: Client.new_batch()}
      assert {:ok, started, 50_000} = reserve(fresh, node())

      settle(
        {:ok, [:not_found, {:error, :too_large}, {:error, :expired}]},
        node(),
        fresh,
        started,
        50_000,
        started + elapsed
      )

      assert :atomics.get(fresh.batch, 1) == 250_000 - charged
      assert :ets.tab2list(:counter_budget_test) == []
    end
  end

  test "timeouts mark cooldown only with sufficient allowance; unavailable always does", %{
    event: event,
  } do
    for {failure, allowance, marked?} <- [
          {{:error, :timeout}, 24_999, false},
          {{:error, :timeout}, 25_000, true},
          {{:error, :unavailable}, 10_000, true},
        ] do
      :ets.delete_all_objects(:counter_budget_test)
      fresh = %{event | batch: Client.new_batch(), timeout_us: allowance}
      assert {:ok, started, ^allowance} = reserve(fresh, node())

      settle(
        {:ok, [:not_found, failure]},
        node(),
        fresh,
        started,
        allowance,
        started + 5_000
      )

      assert :ets.lookup(:counter_budget_test, node()) != [] == marked?
      assert :atomics.get(fresh.batch, 1) == 245_000
    end
  end

  test "cooldown precedes exhausted admission and never reserves", %{event: event} do
    :atomics.put(event.batch, 1, 0)
    assert reserve(event, node()) == :exhausted
    :ets.insert(:counter_budget_test, {node(), System.monotonic_time(:microsecond) + 1_000_000})
    assert reserve(event, node()) == :cooldown
    assert :atomics.get(event.batch, 1) == 0
  end

  test "admission and settlement do not wait for the cooldown owner", %{event: event} do
    owner = Process.whereis(:counter_budget_test)
    :sys.suspend(owner)

    task =
      Task.async(fn ->
        assert {:ok, started, reserved} = reserve(event, node())
        settle({:error, :unavailable}, node(), event, started, reserved, started + 1_000)
        assert reserve(event, node()) == :cooldown
        assert :atomics.get(event.batch, 1) == 249_000
        :ok
      end)

    try do
      # Only a call that waits on the suspended owner would run out this time.
      assert Task.yield(task, 5_000) == {:ok, :ok}
    after
      Task.shutdown(task, :brutal_kill)
      :sys.resume(owner)
    end
  end

  test "unavailable owners outside connected membership never enter cooldown", %{event: event} do
    owner = :counter_missing@localhost
    refute owner in [node() | Node.list()]
    assert {:ok, started, reserved} = reserve(event, owner)
    settle({:error, :unavailable}, owner, event, started, reserved, started + 1_000)
    assert :ets.tab2list(:counter_budget_test) == []
    assert :atomics.get(event.batch, 1) == 249_000
  end

  test "expired events and subminimum budgets skip; unused reservations refund", %{event: event} do
    expired = %{event | deadline: System.monotonic_time(:microsecond) - 1}
    assert reserve(expired, node()) == :exhausted
    :atomics.put(event.batch, 1, 9_999)
    assert reserve(event, node()) == :exhausted
    assert :atomics.get(event.batch, 1) == 9_999
    :atomics.put(event.batch, 1, 10_000)
    assert {:ok, _, 10_000} = reserve(event, node())
    refund(event, 10_000)
    assert :atomics.get(event.batch, 1) == 10_000
  end
end

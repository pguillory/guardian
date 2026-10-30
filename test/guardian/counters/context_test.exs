defmodule Guardian.Counters.ContextTest do
  # Not async: relaxes the node-wide counter budgets.
  use ExUnit.Case, async: false
  alias Guardian.Counters.Budget
  alias Guardian.Counters.Client
  alias Guardian.Counters.Context
  alias Guardian.Counters.Store
  alias Guardian.Counters.Transport
  alias Guardian.Test.Counters.Budget, as: CounterBudgetHelper

  test "Client captures a typed context with the existing defaults and shared batch" do
    batch = Client.new_batch()
    before = System.monotonic_time(:microsecond)
    context = Client.new_event(batch)
    after_capture = System.monotonic_time(:microsecond)

    assert %Context{
             batch: ^batch,
             timeout_us: 50_000,
             cooldown_table: Budget,
             store: Store,
           } = context

    assert context.deadline >= before + 100_000
    assert context.deadline <= after_capture + 100_000
    assert [local | peers] = context.members
    assert local == node()
    assert Enum.all?(peers, &is_atom/1)
    assert CounterBudgetHelper.remaining_us(batch) == 250_000
  end

  test "test overrides replace the event and call budgets" do
    batch = Client.new_batch()
    table = make_ref()
    members = [:counter_context@localhost]

    for {event_ms, operation_ms, expected_event_us, expected_operation_us} <- [
          {7, 3, 7_000, 3_000},
          {200, 90, 200_000, 90_000},
          {-1, 0, -1_000, 0},
        ] do
      before = System.monotonic_time(:microsecond)

      context =
        Client.new_event(batch,
          event_timeout_ms: event_ms,
          timeout_ms: operation_ms,
          cooldown_table: table,
          members: members,
          store: self()
        )

      assert context.deadline >= before + expected_event_us
      assert context.deadline <= System.monotonic_time(:microsecond) + expected_event_us
      assert context.timeout_us == expected_operation_us
      assert context.cooldown_table == table
      assert context.members == members
      assert context.store == self()
      assert context.batch == batch
    end
  end

  # Only this test changes the runtime budgets: it tests the configuration seam itself.
  test "the internal budget seam replaces defaults and the remote endpoint bound" do
    batch = Client.new_batch()
    store = start_supervised!({Store, name: nil})
    probe = {:batch, [{:get, {{"events", "hits", "seam"}, {}, 1}}]}

    assert Transport.remote_operation(probe, store, 50) == {:ok, [:not_found]}
    assert Transport.remote_operation(probe, store, 51) == {:error, :invalid_request}

    CounterBudgetHelper.relax()
    before = System.monotonic_time(:microsecond)
    relaxed = Client.new_event(batch)
    assert relaxed.timeout_us == 1_000_000
    assert relaxed.deadline >= before + 900_000
    assert relaxed.deadline <= System.monotonic_time(:microsecond) + 900_000
    assert Client.new_event(batch, timeout_ms: 7).timeout_us == 7_000
    assert Transport.remote_operation(probe, store, 1_000) == {:ok, [:not_found]}
    assert Transport.remote_operation(probe, store, 1_001) == {:error, :invalid_request}

    # A value that is not a positive integer keeps the production bound.
    Application.put_env(:guardian, Context, operation_ms: :unbounded, event_ms: 0)
    assert Client.new_event(batch).timeout_us == 50_000
    assert Transport.remote_operation(probe, store, 51) == {:error, :invalid_request}
  end
end

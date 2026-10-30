defmodule Guardian.Counters.ContextTest do
  use ExUnit.Case, async: true
  alias Guardian.Counters.Budget
  alias Guardian.Counters.Client
  alias Guardian.Counters.Context
  alias Guardian.Counters.Store
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
end

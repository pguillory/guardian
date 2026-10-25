defmodule Guardian.Counters.ContextTest do
  use ExUnit.Case, async: false
  alias Guardian.Counters.{Budget, Client, Context, Store, Transport}
  alias Guardian.Rules.Event

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
    assert :atomics.get(batch, 1) == 250_000
  end

  test "test overrides preserve shortened deadlines and upper caps" do
    batch = Client.new_batch()
    table = make_ref()
    members = [:counter_context@localhost]

    for {event_ms, operation_ms, expected_event_us, expected_operation_us} <- [
          {7, 3, 7_000, 3_000},
          {200, 90, 100_000, 50_000},
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

  test "starting an Event preserves private arrival coordinates and nests the typed context" do
    arrival = %Event{arrival_ms: 123, monotonic_ms: -456}
    batch = Client.new_batch()
    first = Event.start(arrival, batch, members: [node()])
    second = Event.start(arrival, batch, members: [node()])

    assert arrival.counters == nil
    assert %Event{arrival_ms: 123, monotonic_ms: -456, counters: %Context{batch: ^batch}} = first
    assert second.arrival_ms == first.arrival_ms
    assert second.monotonic_ms == first.monotonic_ms
    assert second.counters.batch == first.counters.batch
    assert %Event{counters: %Context{}} = Event.new()
  end

  # The one budget test that uses CounterBudgetHelper: it tests the seam itself.
  test "the internal budget seam replaces defaults, caps and the remote endpoint bound" do
    batch = Client.new_batch()
    store = start_supervised!({Store, name: nil})
    probe = {:batch, [{:get, {{"events", "hits", "seam"}, {}, 1}}]}

    assert Client.new_event(batch, timeout_ms: 90).timeout_us == 50_000
    assert Transport.remote_operation(probe, store, 50) == {:ok, [:not_found]}
    assert Transport.remote_operation(probe, store, 51) == {:error, :invalid_request}

    Guardian.CounterBudgetHelper.relax()
    before = System.monotonic_time(:microsecond)
    relaxed = Client.new_event(batch, event_timeout_ms: 5_000)
    assert relaxed.timeout_us == 1_000_000
    assert relaxed.deadline >= before + 900_000
    assert relaxed.deadline <= System.monotonic_time(:microsecond) + 900_000
    assert Client.new_event(batch, timeout_ms: 1_500).timeout_us == 1_000_000
    assert Client.new_event(batch, timeout_ms: 7).timeout_us == 7_000
    assert Transport.remote_operation(probe, store, 1_000) == {:ok, [:not_found]}
    assert Transport.remote_operation(probe, store, 1_001) == {:error, :invalid_request}

    # A value that is not a positive integer keeps the production bound.
    Application.put_env(:guardian, Context, operation_ms: :unbounded, event_ms: 0)
    assert Client.new_event(batch).timeout_us == 50_000
    assert Transport.remote_operation(probe, store, 51) == {:error, :invalid_request}
  end
end

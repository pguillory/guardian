defmodule Guardian.Counters.ContextSeamTest do
  # Not async: sets the node-wide counter budgets in the application env.
  use ExUnit.Case, async: false
  alias Guardian.Counters.Client
  alias Guardian.Counters.Context
  alias Guardian.Counters.Store
  alias Guardian.Counters.Transport
  alias Guardian.Test.Counters.Budget, as: CounterBudgetHelper

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

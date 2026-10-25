defmodule Guardian.CounterBudgetHelper do
  @moduledoc """
  Gives one test larger counter event and call budgets than production's 100 ms and
  50 ms, so host load is far less likely to turn healthy counter calls into timeouts.

  WARNING: use this only in tests that are not about budgets, deadlines, timeouts or
  cooldowns. It replaces both the default and the cap that `Guardian.Counters.Context`
  and the remote owner endpoint enforce, so a test that relies on production budget
  behavior would silently test something else. Tests must be `async: false`, since
  the setting is node-wide application env.

  Every call, healthy or failed, is still capped by the batch's remaining 250 ms
  allowance (`Budget.reserve/2`), so the effective call budget is 250 ms, and a second
  owner in the same event waits for a refund instead of dispatching concurrently.
  The 900 ms event budget stays under the Runner's 1 s per-row limit.
  """

  @context Guardian.Counters.Context
  @relaxed [event_ms: 900, operation_ms: 1_000]

  @doc """
  Relaxes budgets on this node and on `peers` (which do not load Mix config) until the
  calling test exits, then restores each node's previous setting. Returns a function
  that restores them earlier, for a test whose later phases are about budgets.
  """
  def relax(peers \\ []) do
    Guardian.TestEnv.put([{@context, @relaxed}], [node() | peers])
  end
end

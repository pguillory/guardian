defmodule Guardian.Test.Counters.Budget do
  @moduledoc """
  Gives one test larger counter event and call budgets than production's 100 ms and
  50 ms: `relax/1` so host load is far less likely to turn healthy counter calls into
  timeouts, and `scale/1` so budget tests can keep production's reservation decisions
  with a larger wall-clock unit.

  WARNING: use `relax/1` only in tests whose assertions do not depend on production's
  operation or event budget values (an explicit shorter `timeout_ms` still applies,
  and the 250 ms batch allowance is unchanged). It replaces both the default and the
  cap that `Guardian.Counters.Context` and the remote owner endpoint enforce, so a
  test that relies on production budget behavior would silently test something else.
  Tests of reservation decisions use `scale/1` instead (below). Tests must be
  `async: false`, since the setting is node-wide application env.

  With `relax/1`'s budgets, every call, healthy or failed, is still capped by the
  batch's remaining 250 ms allowance (`Budget.reserve/2`), so the effective call
  budget is 250 ms, and a second owner in the same event waits for a refund instead
  of dispatching concurrently. The 900 ms event budget stays under the Runner's 1 s
  per-row limit.

  `scale/1` is for tests of reservation decisions (how many owners dispatch
  concurrently, who waits for a refund) or of a bound against a full call budget. It
  sets a 1 s operation budget and a 10 s event budget, and the test sets its own batch
  allowance to the multiple of the operation budget it means (`allowance_us/1`, for example five units for
  production's 250 ms of 50 ms calls). Budget compares a reservation only with the
  remaining allowance and its 10 ms minimum, so while every reservation is a whole
  unit and the event deadline does not bind, each decision is the same as in
  production and only the wall-clock unit grows. Budget's 10 ms minimum and 25 ms
  cooldown threshold are not scaled. Such a test must assert no absolute durations or
  allowance values derived from production's 50 ms. Its 10 s event budget exceeds the
  Rules Runner's 1 s per-row limit, so it is not for tests that run rules.
  """

  @context Guardian.Counters.Context
  @relaxed [event_ms: 900, operation_ms: 1_000]
  @scaled [event_ms: 10_000, operation_ms: 1_000]

  @doc """
  Relaxes budgets (900 ms event, 1_000 ms operation) on this node and on `peers`
  (which do not load Mix config) until the calling test exits, then restores each
  node's previous setting. Returns a function that restores them earlier, for a test
  whose later phases are about budgets.
  """
  def relax(peers \\ []) do
    put(@relaxed, peers)
  end

  @doc """
  Scales budgets (10 s event, 1 s operation unit) on this node and on `peers`, with the
  same restore behavior as `relax/1`. Size the test's batch allowance with
  `allowance_us/1` afterwards.
  """
  def scale(peers \\ []) do
    put(@scaled, peers)
  end

  @doc """
  A batch allowance of `multiple` operation budgets on this node's current setting, in
  the microseconds `:atomics.put(batch, 1, _)` takes. Call it after `scale/1`.
  """
  def allowance_us(multiple) do
    multiple * Guardian.Counters.Clock.from_ms(@context.operation_ms())
  end

  defp put(budgets, peers) do
    Guardian.Test.Env.put([{@context, budgets}], [node() | peers])
  end
end

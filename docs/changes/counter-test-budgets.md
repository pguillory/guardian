# Counter test budgets and peer readiness

Status: implemented and validated.

Product spec impact: none. No statements change in overview.md or spec.md.
Production counter budgets, caps, cooldowns and results are unchanged.

## Problem

Under host load (1-minute load around 10 to 17), counter tests failed with
`{:error, :timeout}` or all-zero TRACK results:

1. ClientTest "pending healthy owners use refunds..." against four freshly started
   peers, and "peer get/gets/CAS/incr carry native terms...".
2. CounterIngestTest "real peer owner handles healthy concurrent events...": one slow
   call put the peer in its one-second cooldown, so every later event in the
   60-event burst fell back to the default 0.
3. CounterIngestTest "cross-table lookups..." and "a later rule or storage
   failure...", on the local node only.

A fresh peer loads code lazily and is still finishing its boot, so its first
pipelines are slow. Every call was capped at 50 ms and every event at 100 ms in
code, and the ingest path offers no per-call options, so a test had no way to give
healthy calls more time.

## Change

1. `Guardian.CounterClientHelper.await_ready/2` is a readiness barrier: it calls the
   real remote owner endpoint until a node answers three consecutive missing-key
   reads within 20 ms each, and raises after 10 s for the whole set. It bypasses Budget, so it leaves
   no cooldown or allowance state. `start_store/1` also loads the counter call path
   on the peer before any budgeted call.
2. `Guardian.Counters.Context` reads `config :guardian, Guardian.Counters.Context,
   event_ms: _, operation_ms: _` at runtime. Each value replaces both the default
   and the cap; the remote endpoint's bound uses the configured call value. The
   defaults are exactly the previous 100 ms and 50 ms, values other than positive
   integers keep them, and no configuration sets them, including the test
   configuration. Like Transport's compile-time
   `store_backend`, this is an internal test seam, not an operator setting.
3. `Guardian.CounterBudgetHelper.relax/1` raises them (900 ms event, under the
   Runner's 1 s row limit; 1 s call) on the test node and named peers for one test,
   restoring them on exit or earlier through the function it returns. Every call is
   still capped by the batch's remaining 250 ms allowance, so the effective call
   budget is 250 ms. Only tests not about budgets use it: the native-terms peer
   test, the healthy burst of the real-peer ingest test (its failure, cooldown and
   recovery phases restore production budgets first) and the two local ingest
   tests, plus the seam's own test in ContextTest. Budget-semantics tests keep
   production values.

## Validation

Independent Claude and Codex plan and code reviews approved this change.
Before the fix, 3 of 4 runs of ClientTest and CounterIngestTest failed at 1-minute
load 10 to 17. With the fix, 10 of 10 sequential runs of those files and
ContextTest passed at load 6 to 9, but the unfixed code also passed 4 of 4 at that
load, so these runs do not show a lower failure rate under the original heavier
load. Load was held under about 14 by agreement, so no heavier run was made. The
full suite passed once after review.

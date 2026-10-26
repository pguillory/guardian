# Counter test budgets and peer readiness

The shared helpers named below now live under `Guardian.Test.*`; see
[test support namespace](test-support-namespace.md) for the mapping.

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
   budget is 250 ms. Only tests not about budgets use it. Its first users were the
   native-terms peer test, the healthy burst of the real-peer ingest test (its failure, cooldown and
   recovery phases restore production budgets first) and the two local ingest
   tests, plus the seam's own test in ContextTest (more were added later; see the
   follow-up below). Budget-semantics tests kept production values (changed in the
   budget-semantics follow-up below).

## Validation

Independent Claude and Codex plan and code reviews approved this change.
Before the fix, 3 of 4 runs of ClientTest and CounterIngestTest failed at 1-minute
load 10 to 17. With the fix, 10 of 10 sequential runs of those files and
ContextTest passed at load 6 to 9, but the unfixed code also passed 4 of 4 at that
load, so these runs do not show a lower failure rate under the original heavier
load. Load was held under about 14 by agreement, so no heavier run was made. The
full suite passed once after review.

## Follow-up: more healthy-call tests (2026-10-25)

ClientTest "owner pipelines run concurrently, group every key, and refund healthy
waits" failed once in its second sub-case: the first owner's call, capped at a 50 ms
batch allowance, timed out during the test's deliberate 15 ms hold before release.
That sub-case tests that a queued owner's anchored write expiry is checked when it
actually dispatches, not production timeout values, so it now relaxes budgets on this
node and the peer and uses the default 250 ms allowance. The first owner's call still
reserves the whole allowance, so the second owner still queues for its refund. The
sub-case restores production budgets before the third, which tests exhaustion, and the
first sub-case stays on them because relaxed reservations would serialize its two
owners instead of running them concurrently. 250 ms is a larger scheduling margin,
not a guarantee.

These tests make healthy budgeted calls whose success they assert and are not about
budgets, so they now relax budgets too: in ClientTest "atom group terms route and
store", "local native operations preserve nil, tokens, colocation and definite
errors" and "successful error-shaped values remain opaque through local and peer
pipelines" (its full-refund check still holds); in CounterIngestTest "HTTP and MCP
return LOOKUP=49/TRACK=50...", "a count outside int64 is refused..." and "unkeyed
resubmissions count twice...".

ClientTest "large healthy local and peer batches never spend the failure budget"
makes the most healthy budgeted calls (600) but checks failure-budget accounting, so
it stays on production budgets, as do "pending healthy owners use refunds..." (its
later phase relies on five concurrent 50 ms reservations) and every timeout,
cooldown, stall, deadline and duration-bound test (changed in the budget-semantics
follow-up below).

This pass covered only ClientTest and CounterIngestTest. Other files also make
healthy budgeted counter calls on production budgets, all local only and none seen
failing (Rules.CounterReloadTest, Rules.CounterRuntimeTest, Rules.ServerTest and
Web.MCP.RulesToolsTest); they are unchanged.

Independent Claude and Codex plan and code reviews approved this follow-up. Focused
runs of ClientTest and CounterIngestTest at 1-minute load around 20 had no failures
in the changed tests; the failures they did show were in unchanged budget tests
("pending healthy owners use refunds..." and "booting and lost owners fail
immediately..."), recorded separately. The full suite passed once at load about 3.

## Follow-up: budget-semantics tests (2026-10-25)

The tests above stayed on production budgets because they are about budgets. Under
host load they failed too: "pending healthy owners use refunds..." (every fresh peer
timed out, or the sixth owner never started) and "booting and lost owners fail
immediately..." (`:timeout` instead of `:unavailable`), and repeated runs found more.
In each, 50 ms is both the size of a reservation and a call's wall-clock deadline.
These tests now handle that in one of four ways. Production budgets are unchanged.

1. Scaled budgets, for tests of reservation decisions or of a bound against a full
   call budget: `CounterBudgetHelper.scale/1` sets a 1 s operation budget and a 10 s
   event budget, and `allowance_us/1` gives a batch allowance of that many operation
   budgets. The test sets the allowance to the
   multiple production uses (five units, as 250 ms is five 50 ms calls). Budget
   compares a reservation only with the remaining allowance and its 10 ms minimum, so
   while every reservation is a whole unit and the event deadline does not bind (true
   in these tests), each decision is the same as in production, and a held call gets
   a 1 s deadline instead of 50 ms. Budget's 10 ms minimum and 25 ms cooldown
   threshold are not scaled. Allowance assertions use the same units. Users of this:
   - ClientTest "pending healthy owners use refunds...": five reservations still take
     the whole allowance (now asserted, together with the sixth owner not starting
     before the refund), and one unit still serializes the owners.
   - The first sub-case of "owner pipelines run concurrently...": two held owners still
     reserve concurrently. It restores the previous values before the second
     sub-case relaxes budgets again, and the third sub-case runs on production values.
   - "batch caller death..." and "caller death conservatively charges...": the caller
     is still killed while its call is outstanding. Production's 50 ms call could time
     out first, which failed the second test and let the first pass without checking
     anything, so the first now asserts that the helpers existed, as the second did.
     The retained reservation is still one unit, and the wait for the queued
     mutation's deadline is one unit plus 5 ms.
   - "cooldown expires..., absent routing fails fast": see item 3.
2. Plain relax, where the assertion does not depend on the budget:
   - "booting and lost owners fail immediately...": the result codes come from the
     peer's refusal and the cooldown that refusal marks, and no timing is asserted.
     The peer is also relaxed (otherwise its endpoint refuses a longer duration) and
     preloads the whole counter call path and test doubles, now including Clock and
     the test batch adapter, through the shared `CounterClientHelper.preload/0`, which
     `start_store/1` now uses as well.
   - "large healthy local and peer batches..." (600 calls): a healthy call is
     refunded in full whatever it reserved.
   - "malformed pipeline replies...": a malformed reply is charged its elapsed wait
     and never marks cooldown, whatever it reserved. It timed out on its 2 ms reply.
   - CounterRuntimeTest, every test, from its setup: none depends on the 50 ms or
     100 ms values (its timeout tests pass shorter explicit timeouts, which stay
     capped, and its allowance tests depend on the 250 ms allowance). "every
     registered aggregate tracks..." had every counter default once, consistent with
     a cold first local call timing out.
   - Within it, "many rules across events stop waiting...": the 250 ms allowance
     stops the waits, not the call budget. Its failure (allowance still at 78_156,
     and at 200_000 in another run) is consistent with a 15 ms failure timing out at
     50 ms under load and putting the owner in cooldown, so later calls charged
     nothing.
   - Within it, "concurrent generic CAS updates...": its final lookup returned nil
     once. That matches the fail-open result of a node in cooldown (putting the
     node in cooldown before the lookup gives exactly nil), and in this local test
     with a healthy store only a call that timed out could put it there. The failure
     did not recur in 151 focused runs, so the cause was not observed directly, but
     it is consistent with timing rather than a CAS fault. Its assertions don't
     depend on the budget.
   - Local-only tests asserting healthy counter results, none seen failing:
     CounterReloadTest (all tests, from its setup), ServerTest "invalid counter
     writes save nothing and valid counters execute..." and RulesToolsTest "counter
     writes reject invalid definitions...".
3. Looser duration bounds. Each upper bound is now commented with the behavior it
   rules out, and loosened only as far as it still separates that behavior from the
   healthy case:
   - "local stall times out...": < 1_000 ms (was 200). It rules out waits far beyond
     the 50 ms call budget, such as one bounded only by the paused store, which never
     answers. This loses sensitivity: it no longer catches a wait of
     a few hundred ms (for example a deadline taken from the 250 ms allowance), which
     can't be told apart from host load on production budgets. The result codes still
     assert the timeout and the cooldown.
   - "long batches stop failed waits..." and "frozen peer and distribution
     backpressure...": < 1_500 ms (was 750). A call that outlived its 15 ms deadline
     would hang on the paused store or the stopped peer. The shared cap is proven by
     counting outcomes instead (1 to 25 timeouts, against 100 or 60 without the
     cap); the first of these tests gained that count. These lose sensitivity too:
     neither the bound nor the count (charges stay capped at 15 ms) catches failed
     calls that wait out the 50 ms default instead of their 15 ms timeout
     (17 x 50 ms is about 850 ms).
   - "cooldown expires..., absent routing fails fast": < 500 ms (was 50), with the
     scaled 1 s budget and an allowance of five units, so failing fast stays clearly
     below the full 1 s call budget a waiting call could take.
   - CounterRuntimeTest "many rules across events...": < 2_500 ms (was 1_000). It
     rules out events waiting out their whole 900 ms event budgets (over 20 s for 25
     events). The dispatch count still proves the allowance.
4. Unchanged: "one stalled owner does not lose another owner's results..." makes one
   healthy local call alongside a remote 50 ms timeout and asserts an allowance range
   derived from 50 ms; it has not been seen failing. Also on production budgets, and
   not seen failing: the healthy `{:ok, 1}` call after "local stall..."'s cooldown,
   and "the renamed remote endpoint preserves...", a healthy peer call with a 50 ms
   duration. "short call and exhausted event budget...", "overlapping callers..." and
   "deadline races..." assert only decisions.

Validation: independent Claude and Codex code reviews approved this follow-up after two
rounds (the first found that the absent-routing bound did not separate fail-fast from
a capped 250 ms wait; fixed). Repeated focused runs passed: ClientTest 31/31 at
1-minute load 7 to 13 with the review fixes (later changes there were comments only)
and 41/41 at load 16 to 32 before them; "booting and lost owners..." 61/61
at load 14 to 18; CounterRuntimeTest 21/21 at load 11 to 13; CounterReloadTest,
ServerTest and RulesToolsTest (with CounterRuntimeTest) 16/16 at load 14 to 17.
Earlier runs during the work failed only in tests this follow-up then changed. The
full suite passed once, in this change's pre-commit run.

These are larger margins, not a removal of wall-clock dependence: held calls can still
time out after 1 s, relaxed calls are still capped by a 250 ms allowance, and the
readiness barrier still needs three replies of at most 20 ms.

## Follow-up: ClientTest allowance helpers (2026-10-25)

Product spec impact: none. No statements in `docs/product/overview.md` or
`docs/product/spec.md` change; production code is unchanged.

ClientTest now builds shared-batch contexts through its existing event helper,
with the same store, membership and cooldown defaults and per-event overrides.
`Guardian.Test.Counters.Budget.batch/1` creates an allowance measured in current
operation budgets, `batch/2` resets an idle batch (including the zero/refill
validation case), and `remaining_us/1` reads its allowance. Within ClientTest,
only the helper needs to know Budget's atomics slot. Fractional multiples are rounded to microseconds;
the 0.4-unit case retains its 20 ms allowance on production budgets and does not
claim the whole-reservation equivalence of scaled budget tests.

Test scenarios, assertion values, budget transitions and cleanup are preserved.
ContextTest's and CounterRuntimeTest's direct allowance access remains outside
this ClientTest refactor.
The three residual timing cases listed in item 4 above remain unchanged: this
allowance seam does not control transport scheduling or remote clocks, so making
them deterministic would need a separate timing mechanism.

Validation: the focused ClientTest and ContextTest run passed with warnings as
errors: 30 tests, no failures. No test cases were added or removed.

# Rule tests run async

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Only tests, test support and notes for contributors change.

## Why they can

Every rule write on a node queues on the one `Guardian.Rules.Server`, which takes and
releases the store's write lock inside its callback. So two tests never meet at the lock:
`{:error, :busy}` cannot happen between tests on the shared store, and the test path needs
no retry. Tests interleave as real callers do.

One write costs 16 ms with an empty set, 28 ms beside 50 other files and 75 ms beside 200
(local store, mean of 50 writes). `with_rules/1` deletes on exit, so the set holds only
running tests' files. A write is refused only for errors it adds, and the API cannot store
an invalid file, so one test's rules cannot fail another's write. Tests that plant files
do it on a fake store, in sync modules. ExUnit runs async modules first, so a sync test's
server restart never overlaps an async write.

## What stays sync, and why

1. `Guardian.Rules.ServerTest`, `Guardian.Web.MCP.RulesToolsBusyTest`: point the node's
   Rules.Server at a fake store.
2. `Guardian.Rules.CounterReloadTest`, `Guardian.Rules.PublisherTest`: restart the server.
3. `Guardian.Rules.RunnerTest`: `publish_module/2` replaces the published map, which the
   server also writes, and a fake module's table goes at the next activation.
4. `Guardian.Rules.CounterIngestTest`: real ingest with TRACK runs on the node-wide
   counter budgets, and a timed-out call sets a node-wide cooldown. Making relaxed budgets
   the run's default was rejected: peers stay on production's, and tests of reservations
   would keep passing while checking less.
5. `Guardian.Rules.ClusterTest`: peers.

## Tests removed

Each broke CONTRIBUTING's Testing or Logging rules: a process crashed on purpose, the
counter store frozen, or a timeout. What that leaves untested:

1. The rule time limit: nothing covers it.
2. Runner relaying a worker's crash, and a raising row storing none of its batch: nothing
   covers these. Raising itself is covered in-process, in `Guardian.Rules.CounterRulesTest`.
3. MCP `send_events` answering a crashing rule with `internal_error`, which was the only
   check that the failure's text stays out of that answer. HTTP's bare 500 is still
   tested.
4. HTTP and MCP failing open with a frozen store: covered below that level by
   `Guardian.Test.Counters.ProbeStore` tests. A slow store setting a cooldown and
   recovering is covered by the peer test, which is excluded by default.
5. Failed calls charging one allowance across a run's events through rules: covered at
   the Client level. The rules test now starts from an exhausted allowance, because the
   charge is elapsed time and the old test slept to earn it.

The worker-replacement test now goes over the heap limit instead of killing the worker. A
heap limit is a product outcome Runner handles, one event failing with no crash report.
The boot-retry tests are tagged `:lifecycle`: they need a real start and real backoff.

## Loading code before the run

Going async exposed lazy code loading: the first MCP client in a run spent about 2 s,
sometimes over its 3 s limit, loading Anubis's modules one at a time under load, and a
first rule ran past its 1 s limit once. `test/test_helper.exs` now loads every started
application's modules before any test runs.

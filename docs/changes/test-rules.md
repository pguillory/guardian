# Test rules

Status: in progress.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Tests, CONTRIBUTING.md and TODO.md only; no `lib/` changes.

## Problem

A passing `mix test` printed hundreds of lines and took about three minutes, much of
it waiting out real timeouts and restart spacing, and some tests were flaky under
load. Many tests checked how Guardian copes with its own parts failing rather than
what it does when they work.

## Rules

CONTRIBUTING.md's "Testing philosophy" section, Preston's framing: most tests drive the
user primitives (rules, events, queries) async on their own tables; network tests are
one success and one error per MCP tool and API call; Storage is tested at its module
boundary; clean functions get unit tests. Tests don't peek inside or touch processes,
don't kill, freeze or break internals, test no timeouts and don't sleep. Peer VM tests
are tagged `:cluster` and excluded by default. Restart and durability are checked by
hand when a change touches segment lifetimes or persistence. It is the direction for
new tests; existing tests are brought in line a category at a time, as Preston
decides each.

## Changes

1. Supervisor-tree kills, Storage: SegmentOwnerExitsTest loses its segment-death,
   manager-exit and racing-deletion tests (15 of 20), MutableSegmentsTest its
   killed-segment test, and UnreadableSegmentsTest its startup test, which restarted
   LoadedSegments (the rescan test covers the same loading code). Tests that inject
   other failures (dead PIDs, suspended processes, timeouts) stay until their own
   category is decided. The deleted manager-exit tests had surfaced the FullSegments
   crash cascade, now an open TODO item (full-segments-crash-cascade).

2. Supervisor-tree kills, the rest: tests that terminate, restart or kill a process the
   application's supervisors own. SystemStatsTest's counter-availability and
   Storage-down tests (a check that metrics report counters available replaces the
   first), HealthTest's 503 test (a 200 check replaces it), LoggerTest's unwritable-log
   test, IngestRetryTest's stopped-coordinator test, QueryLogTest's and
   QueryParseErrorsTest's stopped-recorder tests, CounterIngestTest's stopped-Store test
   and the Store restart inside its HTTP/MCP test, Rules.ServerTest's three restart
   tests (their status-redaction check stays as its own test) and CounterReloadTest's
   restart test. HealthTest no longer touches anything shared and goes async.
   Kept under the hold, as not clearly a kill or restart of a supervised process:
   Counters.RuntimeTest (a private, test-started tree), PublisherTest's stops of
   Rules.Server to drive Publisher directly, Rules.ServerTest's crashing-store test,
   `restart_server` as test infrastructure, and kills of query workers, segments in
   query tests and other test-started processes.

3. Peer VM tests are tagged `:cluster` and `test_helper.exs` excludes them: the
   `Guardian.Cluster.*` modules, ClientPeerTest, DistributedStream's ClusterTest and
   PartitionsTest, and Rules.ClusterTest as whole modules, and HeapLimitTest's peer
   describe and CounterIngestTest's peer test alone. `mix test --include cluster` runs
   them; run it before every deploy (CONTRIBUTING.md, the development, Fly and
   single-node guides). The pre-commit hook keeps the default run. Tests that start a
   child VM without joining it to the cluster (DeploymentTest's cookie check,
   SegmentTest's column race) are not peers and stay in the default run.

4. MetadataTest's frozen-node tests go, with their setup: "schema lookups raise
   instead of under-reporting" suspended a peer's Schema and waited out its timeouts
   (about 20 s), and "SELECTs that name their columns need no schema lookup" shared
   that setup. Cluster reliability is for a load test later (run a cluster, send
   traffic, check results), not the suite.

Coverage given up:

- Storage: the only behavioral check that a graceful MutableSegments or
  PersistedSegments stop persists writable segments and the rows reload, and the only
  test of dropping a mutable segment that died.
- /health answering 503 while Storage restarts (spec), and staying Storage-only while
  counters are down.
- SystemStats' tick loop skipping writes while Storage is down and warning once.
- A request or query succeeding, and the failure being logged, when its log table or
  recorder is unavailable (LoggerTest, QueryLogTest, QueryParseErrorsTest).
- HTTP ingestion going ahead without deduplication while the IngestIdempotency
  coordinator is stopped (its unit fail-open test remains), the counter Store restart
  step in CounterIngestTest's HTTP/MCP test, and metrics reporting `counters_available`
  false.
- Counter outage defaults beyond `count()` (count_distinct, sum, min, max, avg and
  LOOKUP), WHERE skips during an outage and the reset after recovery; the paused-store
  tests still cover `count()` fail-open, and secret removal stays covered.
- A Rules.Server restart keeping the published set and its names (spec).
- A started peer that fails a schema lookup failing the statement with a node error
  (spec.md, clustering item 6), and, from the same setup, column-naming SELECTs and
  `count()` reading that peer's rows and a missing table answering `[]` and `[[0]]`.

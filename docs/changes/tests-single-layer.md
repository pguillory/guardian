# Tests stay at one layer and out of internals

Status: implemented.

Product spec impact: none. No statements change in overview.md or spec.md, and no
`lib/` code changes.

## Problem

Many tests froze, killed or peeked inside processes, or forged internal messages,
against CONTRIBUTING's testing philosophy, whose principle is now: try to write each
test at a single layer if possible.

## Change

Those tests are deleted or rewritten at their module's boundary.

1. Deleted: counter tests that froze stores or peers, or looked at helpers and mailboxes;
   distributed stream and query tests of processes, mailboxes and links stopping cleanly
   (global leaks are watched through `system_stats`); receipt tests of coordinator state,
   internal messages and a suspended coordinator; segment age timer tests; tests of
   fake segment refusals and crashes, which no real input reaches; the persister's
   "can't store this segment" test, which hid an error log.
2. Rewritten at one layer: counter sweeps with a short interval and `stats/1`; receipt
   tests through `IngestIdempotency.run/6`; persistence barriers through
   `Guardian.Test.Segments.await_persisted/1`; the stopping flag on a peer VM, not the
   test VM; counter fail-open against a connected peer with no store.
3. Removed helpers: `StorePause`, `PipelineProbe`, and the worker-scanning half of
   `Guardian.Test.Processes`.

## Kept on purpose

- `cluster/query_failures_test` "losing a machine mid-query fails the query": it suspends
  a segment on a peer, against the rule, because it is the only guard at query level
  against silently partial results, and without the freeze it is a race.
- `distributed_stream/cluster_test` suspends `:global_name_server` to isolate real
  connection loss, and waits on `:global`'s lock table in teardown so a wedge fails there.
- `detached_test` kills only processes the test spawned: Detached's contract is about
  process death.

`Guardian.Test.Segments.intercept_append/2` stays while `web/json_api_log_test` uses it.

## No longer tested automatically

Accepted by the maintainer:

- Counters failing open under a stalled store or peer, and helpers not outliving a call.
- Query workers stopping when a query fails or stops early or its caller dies, and a
  killed worker or router failing the pipeline with its reason. Mismatched chunk counts
  are covered only by real disconnects in the `:cluster` suite.
- A stalled receipt coordinator failing open; stale completions, payload retention,
  request binaries pinned by receipts, and the sweep of expired receipts.
- A segment that can't be persisted staying queryable without stopping the persister.
- Segment age timers across rollover and pack, and byte accounting matching packed size.
- A refused row at Engine and Storage where no real input reaches it, and a storage
  failure keeping earlier counter updates.

## Validation

The affected files passed with `--include cluster --include lifecycle`, and the
pre-commit hook's suite passed. Nothing here runs against a deployment.

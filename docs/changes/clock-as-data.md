# Time as data, not an injected clock

## Problem

Three processes took a `:clock` function option so tests could control time:
`Guardian.Counters.Store` (monotonic milliseconds, read per operation and by the
sweep), `Guardian.Web.IngestIdempotency` (monotonic milliseconds for receipt expiry)
and `Guardian.Web.QueryParseErrors` (Unix seconds for the hourly row cap). Function
parameters injected as test seams hide what an operation depends on, and the Store's
clock had also become a fault-injection hook (`Guardian.Test.Counters.StorePause`
swapped it for one that blocked, and tests raised from it).

## Behavior after the change

Operations take the current time as a required argument; nothing takes a clock
function.

1. Store: `get/3`, `gets/3`, `batch/3`, `cas/6` and `incr/5` take `now`, local
   monotonic milliseconds (`System.monotonic_time(:millisecond)` on the store's node);
   a non-integer `now` is `{:error, :invalid_request}`. `stats/1` is unchanged.
   Transport's `local_operation/4` reads `now` on the owner node at dispatch, so the
   remote endpoint's arguments are unchanged and no instant crosses nodes. One `now`
   per request: every operation of a batch judges and sets expiry as of the batch's
   start, where each operation used to read the clock. A batch is bounded by its 50 ms
   operation budget, so a row expiring during a batch can be seen as live for the rest
   of it and later writes in the batch get a slightly earlier expiry; TTLs are
   seconds-scale bucket windows and counters are advisory. Deadlines are still checked
   on the real clock before every operation. The timer-driven housekeeping sweep reads
   the real clock itself (a live time source by nature), so it can still remove rows
   mid-batch, as before.
2. IngestIdempotency: `run/6` is `run(table, key, request, now, ingest, server)`;
   `now` judges expired receipts at the claim. Completion, caller death and the 1 s
   sweep happen inside the coordinator at times no caller argument describes, so the
   coordinator stamps and expires them with its own monotonic clock. Receipts still
   live ten seconds after completion.
3. QueryParseErrors: `record/5` takes `now` in Unix seconds, read by
   `Guardian.Web.Query.execute/3` when the parse error happens, and the cast carries
   its hour. The cap now counts a row in the hour of its parse failure rather than the
   hour the recorder processes it, so a row queued behind a stalled writer counts in
   its own hour. The recorder's hour only moves forward: concurrent callers' casts can
   arrive out of order across an hour boundary, and a late row from an earlier hour
   counts against the current hour, so the cap is never reset twice. If the system
   clock steps backwards, rows count against the latest hour seen until time catches
   up, which can only drop more rows, never exceed the cap.

Test seams that used the Store clock:

- `StorePause` now records a suspended gate in the store's own ETS table (a 2-tuple
  row that Store's operations and housekeeping never match), and the test build's
  `Guardian.Test.Counters.Backend` waits on it before calling Store. The pause comes
  before Store's own deadline checks instead of after them. Transport callers'
  deadlines are anchored before the gate, so a paused caller still times out without
  a late mutation. Direct Store calls bypass the gate: store_test's queued-caller case
  ("a timeout beats a later explicit deadline" for a queued direct caller) lost its
  pause and keeps only its past-deadline assertions; Transport tests cover queued
  callers.
- The per-operation failure test publishes a descriptor whose table is not a table
  (`StorePause.break_entries/2`), instead of a raising clock.
- The housekeeping crash test corrupts the housekeeper's table with
  `:sys.replace_state/2`, instead of a raising clock; it asserts the ETS frame lost
  its arguments and no private value reached the reason or log.
- "The deadline is checked between operations" is now a shape test with no hook:
  4,000 slow-to-encode keys against a 20 ms deadline must give successes (possibly none), then
  only timeouts, and rows only for the successes. It proves nothing mutates after the
  deadline, but not that the cheap check before each operation runs first (the check
  after key encoding would also pass it). Also no longer pinned: the sweep's exact
  `expiry =< now` boundary, a stall inside Store between its entry checks and a
  mutation, and the Store-level closure-frame redaction check (frame redaction stays
  covered in failure_test).

## Product spec impact

None in `docs/product/overview.md` or `docs/product/spec.md` ("at most 60 rows per
machine per clock hour" still holds). Security architecture: none.

## Rolling deploy

No storage change. The counter remote endpoint (`Transport.remote_operation/3`) keeps
its arguments, and each node reads `now` for its own Store, so mixed-version nodes keep
interoperating. The IngestIdempotency calls and the QueryParseErrors cast are
node-local; a release restart replaces each process with its new message shapes.

## Follow-ups

Transport's `now` read has no test that would fail on a wrong unit; probes ignore
`now`. Other function-valued test seams fall under the same rule and are not changed
here:
QueryParseErrors' and QueryLog's `:writer` and `Guardian.Web.Query.execute/3`'s `:execute`
(removed since, `docs/changes/function-test-seams.md`).

# Batched counter state machines

Status: implemented and validated.

Superseded in part by [counter-merge-order.md](counter-merge-order.md): bucket
merge order, and so min/max ties and float results, is no longer a promise.

Product spec impact: [spec Running item 3](../product/spec.md#513-running) now describes
dependency levels and concurrent independent counters; overview unchanged.
TRACK/LOOKUP syntax, LOOKUP-before-TRACK ordering, whole-statement defaults, bucket policy and
availability budgets are unchanged.
This extends the counter implementation in [ingest-rules.md](ingest-rules.md).

## Execution

1. Resolved plans retain dependency levels alongside deterministic flat steps.
   Levels first drain every LOOKUP and its SET ancestors, then remaining SET/TRACK
   dependencies, then UNSETs. Scalar work and counter input preparation finish
   before a level dispatches. A raising SET prevents that level's dispatch;
   SET/UNSET still fail the event.
2. Every applicable statement expands to key machines, one per bucket. LOOKUPs
   read all intersecting buckets. TRACKs read prior buckets and write the current
   bucket concurrently. Zero count deltas only read. Results combine oldest first,
   current last, preserving floating-point order and min/max numeric tie types.
3. Each key machine holds one operation and a response callback. Readers and native
   increments finish in one round. Generic aggregates use gets, merge and CAS,
   skipping unchanged states with strict equality. Only definite conflicts retry,
   with three total attempts. `run_nested` flattens all counters' machine lists,
   executes every pending machine together per round, then restores the exact
   nesting and order, including empty lists.
4. Cluster routing groups each round by owner. Each owner receives one pipeline
   of get/gets/incr/cas operations. Store checks
   its original queued deadline before each operation. A pipeline has at most
   4,000 operations: four buckets times the 1,000-statement table limit. Existing
   scalar client APIs were later retired in [counter-retirement.md](counter-retirement.md);
   Store retains its local atomic primitives.
5. Owner pipelines run concurrently within conservative reservations: each reserves
   up to 50 ms from the shared 250 ms allowance. Undispatched owners wait for any
   completion to refund allowance. The 100 ms event deadline still applies. With
   a nearly spent budget, a slow owner can delay pending healthy owners; calls skip
   below 10 ms remaining. Healthy pipelines refund fully. Any operation error except
   CAS conflict charges one owner wait, bounded by its reservation, using the
   completion timestamp rather than collection time.
6. Each dispatched owner retains its alias, guard and linked worker. Caller death
   retains outstanding reservations conservatively; timeout and cleanup stop the
   helpers and discard late replies. Remote calls translate durations onto the
   owner's clock. Mutations keep fixed expiry metadata until dispatch so pending
   owners and CAS retries do not reset TTLs. Already dispatched writes remain
   uncertain and are never replayed or rerouted.

Missing buckets contribute empty states. Any failed bucket defaults its whole
statement; other statements and final UNSETs continue. Parallel bucket reads and a
writer mean a write can succeed even when another bucket fails and the output
defaults, within the existing advisory, no-rollback contract.

The flat greedy order remains available for metadata and hashing. Breadth-first
levels can order independent statements differently without changing field values:
identifiers are lowercased, outputs are single top-level fields, duplicate outputs
are refused, and UNSETs stay last. Revisit that argument before adding dotted or
quoted outputs. Resolution rebuilds levels after LOOKUP target binding, keeping
execution and recoverable metadata on the same immutable identities.

Run the same build across the cluster. Older peers lacking pipeline support return
invalid-request errors and default counters during a mixed-version rollout; that
definite error does not trigger cooldown. No deployment is part
of this change. The later [counter-store.md](counter-store.md) redesign moves
Store operations directly to public ETS and capacity/expiry reclamation into
housekeeping; the batching protocol and availability budgets remain.

## Validation

Targeted tests cover round/nesting behavior, strict equality, CAS limits, expiry,
ordered store pipelines, per-operation deadlines, owner concurrency and grouping,
healthy reservation refunds with six owners and with a partly spent allowance,
partial owner failure, caller death, helper/reply cleanup, level/bucket batching,
LOOKUP barriers, dependent outputs, whole-statement defaults and final UNSETs.

Independent Claude and Codex plan and code reviews approved the change after
corrections. The final pre-commit passed formatting, warnings-as-errors compilation
and the full default suite: 1,169 tests, zero failures, three excluded large tests.

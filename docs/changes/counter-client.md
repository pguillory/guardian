# Counter client, transport and budget boundaries

Status: implemented and validated.

Product spec impact: none. No statements change in overview.md or spec.md.
TRACK/LOOKUP results, fail-open defaults, owner routing, batches, deadlines,
cooldowns and failed-wait budgets remain unchanged.

`Guardian.Counters.Client` is the facade used by Rules and the key-machine runner:
`new_batch/0`, `new_event/2` and `batch/2`. It starts the event deadline before
snapshotting membership, as before. There are no scalar client operations.

Internal `Guardian.Counters.Transport` owns typed rendezvous hashing, grouping
indexed operations into sorted owner pipelines, anchored TTL preparation at actual
dispatch, concurrent pending/running pipelines, reply normalization and the bounded
guard/linked-worker lifecycle. It owns local Store dispatch and the remote endpoint.
It is not a supervised process.

Internal `Guardian.Counters.Budget` owns event deadlines, atomic reservations,
refunds, failed-wait settlement and owner cooldowns. Its supervised GenServer owns
only cooldown ETS lifecycle, membership monitoring and cleanup; the hot path stays
in atomics/ETS, without mailbox waits. It replaces Cluster after Store in the same
disposable supervisor. Process-presence availability now checks Store and Budget.
The internal supervisor option is renamed from `:cluster` to `:budget`.

Cooldown admission still precedes the dispatch clock and reservation. Operations
reserve at most 50 ms from the shared 250 ms batch allowance within the 100 ms event
phase, skipping below 10 ms. Pending owners can use completion refunds. Settlement
charges failed pipeline waits once, using the completion timestamp, and unwraps
the normalized pipeline once: successful values containing error-shaped terms are
healthy. Missing/CAS conflicts refund fully; caller death retains outstanding
reservations. Unavailability marks a one-second cooldown, and timeout does so only
with at least 25 ms allowance. Uncertain writes are never replayed or rerouted.

## Compatibility

The former `Guardian.Counters.Cluster` module is removed, including its remote
entry point. RPC now targets `Guardian.Counters.Transport.remote_operation/3`.
The batch-only operation terms, values, opaque CAS tokens and duration arguments
are unchanged. The module name on the wire changes, so multi-node rolling deploys
across this commit are unsupported, as with the Guardian namespace rename. Old
callers to new nodes and new callers to old nodes encounter a missing endpoint,
return unavailable, mark owner cooldown and use fail-open defaults. All nodes must
restart on the same build for reliable distributed counters. No disk migration is
needed. No deployment or production verification is part of this change.

## Validation

Independent Claude and Codex plan reviews approved the split. Both highlighted
one-level settlement classification for successful values containing error-shaped
lists; focused Budget coverage pins that boundary alongside existing pipeline,
deadline, cooldown, cleanup and restart tests through the Client facade.
Focused counter and affected rule tests passed: 99 tests, zero failures, with
warnings-as-errors enabled. Both code reviewers approved after all five concern
helpers completed for each provider. Nonblocking follow-ups added local/peer
round trips for error-shaped stored values, absent-member cooldown coverage,
a bounded mailbox-independence assertion and compatibility links in operator
guides. The affected Client/Budget tests then passed: 30 tests, zero failures.
The sole full pre-commit passed formatting, warnings-as-errors compilation and
the default suite: 1,193 tests, zero failures, three excluded large tests. No
deployment, production-data writes or hardware verification was performed.

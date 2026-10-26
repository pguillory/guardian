# Counters

Ephemeral counter infrastructure for the reviewed TRACK/LOOKUP v1 design in
`docs/changes/ingest-rules.md`. The node-local store, cluster routing and pure
aggregate operators and live rule execution (`Guardian.Rules.CounterRuntime`) are
implemented. TRACK/LOOKUP are available through normal whole-set rule writes,
startup and reload. GUARDIAN_COUNTER_MEMORY_MB sets positive MiB, default 64;
explicit empty/invalid values refuse startup.

`Guardian.Counters.Store` owns one public ETS set. Registered stores use the same
table name; callers find a descriptor row through ETS, never the owner's mailbox.
Unnamed stores may use a PID (process dictionary lookup) or table reference.
User keys are deterministic ETF binaries; the reserved atom descriptor key cannot
collide. ETF is ephemeral and owner-local; routing hashes terms with `:erlang.phash2/2`.
Rows are {encoded_key, value, expires_at, version}. The GenServer only runs
housekeeping; suspending it must not block normal named-store traffic.
Start it after Guardian.Rules.Server and before Storage, under the existing
Supervisor/Restarter boundary. Invalid options refuse startup. Restart isolation,
backoff and process-presence stats remain as specified in system.md section 2.1.

1. Preserve missing versus stored nil. get/gets use lookup; CAS uses keyed
   select_replace with a fully bound binary key and constant replacement values.
   Missing CAS uses insert_new. Native incr uses one update_counter list for the
   value, a fresh positive unique version (threshold/reset), and expiry readout.
   Tokens carry table generation and version; every mutation, including delta zero,
   invalidates prior tokens. Never expose the token's representation as a product API.
2. Expiry is owner's monotonic now plus the initial positive TTL, retained by
   updates. Bucket callers send decreasing remaining TTL to bucket_end+window;
   remote clocks receive durations, never another VM's monotonic timestamp.
   Reads treat expiry<=now as missing. A physically present expired key can be
   conditionally deleted and reused with one retry; ordinary bucket traffic does
   not revisit expired bucket identities. Check deadlines after clock/key encoding
   and before retries. Stale CAS never recreates a key. A second expired increment
   returns :expired, a definite failure alongside :not_integer and :too_large.
3. One tagged timer chain runs bulk expiry deletion about every second. Memory
   reclamation samples up to 256 expiries and deletes through their median cutoff;
   tied expiries may remove more than half. Run at most four eviction passes per
   tick, then continue immediately if still over. Never reclaim in a write.
4. Preserve the 64 MiB default and individual oversized-payload refusal.
   Housekeeping and diagnostic stats fold resident rows, charging ETS bytes above
   fixed descriptor/empty overhead plus serialized encoded keys/values and backing
   allocations retained by nested value binaries/bitstrings/function environments.
   Encoded keys copy their bytes, detaching original key slices. The budget is an
   asynchronous target: writes can overshoot between sweeps and during concurrent
   reclamation. Accounting is approximate during concurrent changes; stats scans
   are diagnostic. Excludes temporary copies, mailboxes and other VM memory.
   Successful writes return success even if housekeeping later evicts them.
5. Operations check real monotonic deadlines; batch executes at most 4,000 operations
   in order, with a check before each, without rollback or a multi-key snapshot.
   Budget retains its wait budgets/cooldowns and never replays uncertain increments.
   Test builds select a libtest batch adapter at compile time; only that adapter
   interprets the internal {backend_module, server} store option for transport probes.
   Production calls Store directly, with no backend tuple handling or mailbox fallback.
   Context's `event_ms`/`operation_ms` application env is the other internal test
   seam: it replaces the 100/50 ms defaults and caps, including the remote endpoint
   bound. Never set it outside tests; only `Guardian.Test.Counters.Budget` does, for
   tests not about budgets, the seam's own test, and budget tests that scale the
   operation budget (`scale/1`) and size their batch allowance in units of it
   (`batch/1`, with `allowance_us/1` for expected values), with no durations or allowances derived from 50 ms
   (`docs/changes/counter-test-budgets.md`).
6. Return fixed errors; no key/value/exception logging. Housekeeping callback
   failures scrub stacks through `Guardian.Failure.stacktrace/1` and reset the
   store. Status redacts state/messages/logs.
   Tests use a private injectable expiry clock, while deadlines use real time;
   fault injection pauses callers through a libtest clock gate, not the housekeeper.
   Store validates request options explicitly (`:invalid_request`) and catches any
   other request failure as `:unavailable`; that catch is its deliberate boundary for
   direct callers and the remote endpoint. Transport's `operation_owner/2` checks
   anchored increment/CAS expiries are integers before grouping or admission, so
   malformed expiries return `:invalid_request` without reserving allowance.
   It rescues nothing: bad membership is a programming error that Rules records
   and fails open. Translate valid anchored expiries only at actual dispatch.

`Guardian.Counters.Client` is the batched facade used by Rules and Machine. It
returns a typed `Guardian.Counters.Context` nested under
`Guardian.Rules.Event.counters`.
Context captures the event deadline before snapshotting connected members; private
Unix/monotonic arrival coordinates remain on Rules.Event, outside the row. Internal
`Guardian.Counters.Transport` routes `{identity, group_tuple, bucket}` keys with rendezvous
hashing over identity and group only. Each member's score is
`{:erlang.phash2({{identity, group_tuple}, member_name}, 4_294_967_296), member_name}`,
with the highest score winning and member names breaking hash ties
(`Guardian.Rendezvous.owner/3`, with the member name as id). phash2 accepts
any term and distinguishes integers from floats; signed zeros share an owner but
remain distinct stored counters through Store's ETF keys. All buckets share one owner.
Membership comes from this node plus connected peers, once per event, without
Storage readiness calls. Remote endpoints call only the owner's local store.

`Guardian.Counters.Budget` is supervised after Store and owns cooldown ETS lifecycle,
reservations, deadline enforcement and settlement. Its hot path uses atomics/ETS directly;
Transport has no process. Client delegates batch dispatch to Transport, which calls
Budget before dispatch and after normalized pipeline completion. Settlement unwraps
the pipeline once; successful stored values are never inspected for errors.
`Guardian.Counters.Clock` owns the local monotonic microsecond coordinate that
Context deadlines/timeouts, Budget reservations, settlement timestamps and
cooldowns, and Transport dispatch deadlines share; read the clock and convert
ms/us only through it. Store's
`:deadline` stays monotonic ms (`to_store_ms/1`) and mutation TTLs stay on the
Rules arrival milliseconds.

1. Keep `new_batch/0` outside replaceable workers; its atomics handle holds 250 ms
   of failed-call allowance. `new_event(batch)` snapshots members and starts a
   100 ms wall-clock counter phase. Every operation uses at most 50 ms, skips below
   10 ms remaining, and reserves atomically before dispatch. Healthy responses
   (including missing and CAS conflict) refund the full allowance. Failures refund
   unused wait; caller death conservatively retains its outstanding reservation.
2. Local deadlines stay anchored to dispatch; remote endpoints translate a
   remaining duration onto their own clock. Transit and dispatched mutations can
   outlive the caller's wait. Never retry an uncertain increment or fail over to
   another owner. Rule callers alone supply aggregate defaults on errors.
3. A guard and linked worker bound distribution flow-control waits. The guard
   monitors caller death; caller cleanup revokes the reply alias, kills the guard,
   consumes its DOWN, and flushes delivered replies. No caller helper may linger.
4. Cooldown ETS is owned independently of Store, keyed only by members, and cleaned
   on membership changes and every second. Unavailability marks the owner for one
   second; timeout does so only with at least 25 ms allowance. Budget skips and
   definite errors never mark it. Cooldown fast-fail precedes reservation/dispatch.
   Restarting Budget clears cooldown; while absent, calls fail immediately.
5. These counters are ephemeral and advisory. Membership changes, partitions,
   restarts, eviction and uncertain writes can lose or split counts. The remote
   endpoint uses the existing cookie-authenticated, fully trusted distribution
   boundary; it is not an HTTP endpoint or a new authorization mechanism.

`Guardian.Counters.Machine.run_nested/3` preserves counter/bucket nesting while executing
every pending key machine together per round. `Guardian.Counters.KeyMachines` implements
read, incr and gets/merge/CAS response callbacks. Machine errors remain errors:
missing keys alone default at the bucket layer; a failed bucket defaults the whole
statement. Transport batches by owner and dispatches concurrent pipelines. Pending
owners wait for any completed call's reservation refund; cooldown, truly exhausted
budgets or deadlines skip them. Charge failed waits once per pipeline using its
completion timestamp. Recompute anchored mutation TTLs at actual pipeline dispatch,
including after waiting for a reservation. Client exposes only batched operations;
the Transport remote endpoint accepts only owner pipelines. Its renamed RPC module
requires all nodes to restart on the same build; mixed-version rolling deploys across
this split are unsupported (`docs/changes/counter-client.md`). Store retains its
local atomic primitives.

TRACK steps and bound LOOKUPs carry immutable counter definitions. Every registered
`{name, arity}` is a TRACK operator, with the same configuration queries use.
Execution selects the aggregation with `Guardian.Aggregation.fetch!(name)` from
the definition's operator and passes it to key machines. Call
empty/start/merge/finish through the shared registry API.
Every empty is a mergeable state whose finish is the query's no-rows result, which
is also the missing/failed counter result. Distinct uses Hypex precision 8 with
fixed 256-byte bitstring registers. Average keeps `{sum, count}` and skips empty
states without arithmetic, preserving signed zero. Float overflow is absorbing;
integer sum wraps through `Guardian.Query.Numeric`, while average keeps exact integer sums.
Floating-point rounding/cancellation, overflow and wrapping mixed with floats
preclude universal associativity. Min/max share query ordering, with the right
state winning ties, including the type of equal integer/float values. A merge
that raises (top-N states with different n) is a bucket error in Machine, or a
statement failure in combine; both fail open.

Bucket callers merge states, compare with the prior state using `===` to skip
unchanged writes, then finish once. Count finishes raw; the int64 limit applies
where the event is stored. The existing aggregation
modules own all operator arithmetic, Hypex and ordering logic. States are ordinary terms suitable
for ETS/erpc. HLL registers are fixed size; arbitrary, min/max and `_by` states
retain an input-sized value, `_n` states up to n of them, and exact count/avg
integer sizes grow logarithmically rather than having an
absolute byte cap. Preserve Store's payload refusal and asynchronous memory target.
Counter rule execution lives in Rules, with at most three total CAS attempts for
definite conflicts only. See `docs/changes/shared-aggregates.md`,
`docs/changes/counter-retirement.md` and `docs/changes/aggregates-unify.md`.

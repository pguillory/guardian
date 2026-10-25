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
collide. ETF is ephemeral and owner-local, never the cluster's routing encoding.
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
   Cluster retains its wait budgets/cooldowns and never replays uncertain increments.
   The internal {backend_module, server} Cluster store option supports transport
   probes in libtest; production defaults to Store with no mailbox fallback.
6. Return fixed errors; no key/value/exception logging. Housekeeping callback
   failures scrub stacks and reset the store. Status redacts state/messages/logs.
   Tests use a private injectable expiry clock, while deadlines use real time;
   fault injection pauses callers through a libtest clock gate, not the housekeeper.

`Guardian.Counters.Cluster` routes `{identity, group_tuple, bucket}` keys with rendezvous
hashing over identity and group only. Explicit tagged encoding preserves types
(including integer/float and signed zero), supports JSON lists/maps and nested
tuples, rejects other atoms/terms, and stays independent of ETF/OTP versions.
Membership comes from this node plus connected peers, once per event, without
Storage readiness calls. Remote endpoints call only the owner's local store.

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
   Restarting Cluster clears cooldown; while absent, calls fail immediately.
5. These counters are ephemeral and advisory. Membership changes, partitions,
   restarts, eviction and uncertain writes can lose or split counts. The remote
   endpoint uses the existing cookie-authenticated, fully trusted distribution
   boundary; it is not an HTTP endpoint or a new authorization mechanism.

`Guardian.Counters.Machine.run_nested/3` preserves counter/bucket nesting while executing
every pending key machine together per round. `Guardian.Counters.KeyMachines` implements
read, incr and gets/merge/CAS response callbacks. Machine errors remain errors:
missing keys alone default at the bucket layer; a failed bucket defaults the whole
statement. Cluster batches by owner and dispatches concurrent pipelines. Pending
owners wait for any completed call's reservation refund; cooldown, truly exhausted
budgets or deadlines skip them. Charge failed waits once per pipeline using its
completion timestamp. Recompute anchored mutation TTLs at actual pipeline dispatch,
including after waiting for a reservation. Keep no get_many in this execution path.

`Guardian.Counters.Aggregate` is an adapter to the shared `Guardian.Aggregation`
registry and per-aggregate modules, independent of store operations and query
execution. Its fixed `{name, arity}` allowlist is derived from the registry's
explicit counter configurations and exposes create/merge/resolve/default. Every default
is an empty mergeable state: resolve it for zero (count and distinct) or nil
(sum/min/max/avg). Counter sum's empty result is nil, unlike query sum's 0.0.
Distinct uses Hypex precision 8 with fixed 256-byte bitstring registers; query
distinct stays precision 14. Average keeps `{sum, count}` and skips empty states
without arithmetic, preserving signed zero. Float overflow is absorbing;
integer sum wraps through `Guardian.Query.Numeric`, while average keeps exact integer sums.
Floating-point rounding/cancellation, overflow and wrapping mixed with floats
preclude universal associativity. Min/max share query ordering, with the right
state winning ties, including the type of equal integer/float values.

Bucket callers merge states, compare with the prior state using `===` to skip
unchanged writes, then resolve once. Count values returned by native increments
must also be resolved to apply int64 output bounds. The adapter has no operator
arithmetic, Hypex or ordering logic: the existing aggregation modules own it all,
with configured counter policies where needed. States are ordinary terms suitable
for ETS/erpc. HLL registers are fixed size; min/max retain an input-sized value,
and exact count/avg integer sizes grow logarithmically rather than having an
absolute byte cap. Preserve Store's payload refusal and asynchronous memory target.
Counter rule execution lives in Rules, with at most three total CAS attempts for
definite conflicts only. See `docs/changes/shared-aggregates.md`.

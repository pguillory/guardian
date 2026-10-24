# Counters

Ephemeral counter infrastructure for the reviewed TRACK/LOOKUP v1 design in
`docs/changes/ingest-rules.md`. The node-local store and cluster routing are built;
rule statements and aggregate operators follow separately. Do not
describe TRACK/LOOKUP as available until the rule integration lands.

`Counters.Store` owns private ETS tables for entries, insertion order and expiry.
Its serialized get/get_many/gets/cas/incr operations are atomic on one node.
Start it after Rules.Server and before Storage, independently of both. No disk,
external services, credentials, rule text or event logging belongs here.

1. Preserve missing versus stored nil. `:missing` CAS creates only an absent or
   expired key. Every successful mutation, including incr, issues a new reference
   token, so expiry, eviction and restart cannot resurrect an old CAS token.
2. TTLs use the owner's monotonic clock, are checked before access, and are renewed
   only by successful mutations. A bounded periodic expiry sweep cleans quiet
   keys. Counter bucket callers will pass remaining TTL to a fixed expiry.
3. Charge ETS memory in bytes plus serialized payloads for off-heap binaries,
   including whole backing allocations retained by nested binary/bitstring slices
   (also through keys and function environments);
   ignore only fixed empty-table overhead. Reads do not change FIFO order and
   updates keep their original insertion order. At capacity evict the oldest half,
   repeating when large survivors still exceed the budget. Loss is intentional;
   `{:error, :evicted}` means the updated key was evicted, a definite loss.
   `:too_large` can likewise follow eviction when the payload fits but ETS overhead
   pushes it over capacity; only an up-front payload refusal is free of side effects.
4. Calls have a 50 ms default timeout and a local queued-request deadline. Never
   replay uncertain increments. No remote VM may compare its monotonic timestamps
   with ours; the later cluster layer must translate remaining durations.
5. Status and crashes must not expose keys or values. Malformed operations return
   a fixed error. Unexpected internal failures reset the store with scrubbed
   stacks instead of keeping partially changed ETS with stale accounting.
6. The memory budget bounds resident entries/indexes, not mailboxes, temporary
   copies or the VM. Capacity eviction can stall this single owner; the planned
   cluster layer will provide fail-fast cooldown and shared failure-wait budgets.

Tests use unnamed stores and a private injectable TTL clock. Operation deadlines
always use real monotonic time. Keep these tests independent of external services.

`Counters.Cluster` routes `{identity, group_tuple, bucket}` keys with rendezvous
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

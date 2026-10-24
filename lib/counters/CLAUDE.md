# Counters

Ephemeral counter infrastructure for the reviewed TRACK/LOOKUP v1 design in
`docs/changes/ingest-rules.md`. Only the node-local store is implemented so far;
rule statements, cluster routing and aggregate operators follow separately. Do not
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

# Direct ETS counter store

Status: implemented and validated.

Product spec impact: overview none. Spec section 5.1 Counters item 7 now describes
the asynchronous memory target, temporary overshoot, and sampled earliest-expiry
cutoff (including tied expiries). TRACK/LOOKUP syntax, aggregate semantics,
LOOKUP barriers, budgets, cooldowns and GUARDIAN_COUNTER_MEMORY_MB default remain.
This supersedes C1's internal serialized-store contract in ingest-rules.md and the
synchronous reclamation limitation recorded in counter-batching.md.

## Design

One public ETS set stores {encoded_key, value, expires_at, version}. Registered
stores use named ETS lookup and a reserved descriptor row in that same table;
there is no process on the production read/write path. Unnamed stores also accept
PIDs, resolving the table through a process dictionary field, or direct table IDs.
Captured table IDs and generation-bound tokens cannot target a replacement store.
ETS uses read concurrency, automatic write concurrency and decentralized counters.

Keys are deterministic ETF binaries so CAS select_replace and expired-key deletion
have fully bound match heads, avoiding a table scan and match-spec interpretation
of caller terms. Maps, nested match-spec atoms, numeric types and signed zero keep
their identities. This ephemeral encoding is separate from stable cluster routing.
Encoded keys copy their visible bytes and do not retain original key-slice backing.

Reads use lookup and ignore expired rows. CAS uses select_replace, or insert_new
for missing creation. Incr uses one update_counter list to increment the value,
reset the positive version to a new unique integer and return expiry. Its version
threshold/reset rotates the CAS token even for delta zero. CAS retains expiry;
creation establishes owner's now+remaining TTL. Bucket callers already anchor TTL
to bucket_end+window, translating durations onto the remote owner's clock.

A physically present expired row can outlive the one-second sweep or a suspended
housekeeper. Ordinary bucket identities advance rather than being reused after
expiry; direct store callers or replayed internal coordinates may reuse one. Reads see
missing; missing CAS/incr conditionally delete only an expired row and retry once.
Concurrent fresh rows survive cleanup. A stale token never recreates a row.
After update_counter badarg, lookup classifies live nonintegers as :not_integer,
expired/vanished rows for bounded retry and missing tables as :unavailable. A
second expired increment returns :expired; a second create conflict returns
:conflict. These are definite failures, not uncertain live-write replays.
Deadlines are checked after clock/key preparation and before mutations/retries.
Batch keeps the original deadline, runs at most 4,000 ordered operations and
provides no rollback or multi-key snapshot. Cluster's wait budgets are unchanged.

The owner only performs housekeeping: bulk select_delete of expiry<=now, then
memory measurement and eviction. Accounting folds rows to include serialized
encoded keys/values and retained nested value binary backing above ETS's fixed
empty/descriptor overhead. It is approximate under concurrent mutations. Up-front
individual payload refusal preserves an existing value. The memory target is
asynchronous; temporary resident overshoot is possible. Successful writes keep
their success reply even if later housekeeping evicts them.
The per-increment preflight sizes the delta, so unusually large accumulated
integers can also cross that estimate before asynchronous reclamation.

Over budget, sample at most 256 expiries and delete through their median cutoff.
Repeat at most four passes per tick, continuing immediately if still over budget.
Tied expiries can remove every bucket. One tagged periodic timer chain prevents
stale/manual sweeps from creating duplicate chains. No reclamation runs in writes.
The existing counter-only supervision, scrubbed status/failures and advisory loss
model remain. No external service, persistence, deploy or production test is added.

## Validation

Plan review: independent Claude and Codex reviews approved after replacing
guard-only CAS key matching with fully bound encoded binary keys. No separate
follow-up refactor was identified.

Code review: both providers approved after each ran five concern helpers. Their
nonblocking follow-ups aligned remaining product references, added zero-delta and
old-table generation tests, caller-failure and multi-tick eviction coverage, and
kept the startup descriptor unavailable until its baseline was measured. Named
limits and callback stack locations were retained. No later refactor was needed.

Local descriptor experiment (8 callers, 30,000 increments each, OTP 28.5.0.8):
direct table access took about 109 ms versus 547 ms for per-operation process_info.
The implementation therefore uses named ETS lookup and a descriptor row for
production; process_info is only an unnamed-PID convenience.

A local full accounting fold over 150,000 rows with 256-byte binary values
(about 63.4 MiB charged) took about 50 ms on OTP 28.5.0.8. At the default one-second
interval this is roughly 5% of one scheduler for the measurement, before eviction
or expiry work. It copies rows into the housekeeper and temporarily allocates
memory outside the target. This is an observation on one machine, not a latency
guarantee; writes remain independent of that work.

Tests cover concurrent increments and expired-key reuse, CAS races/ABA, literal
keys/values and typed keys, fixed expiry, bulk sweeps/stale tags, asynchronous
expiry-first budget reclamation/cutoff ties, value backing accounting and detached
key slices, direct operations with suspended housekeeping, scrubbed failures and
deadline skips after a blocked clock. Existing cluster/rule fault tests now pause
operation callers through a libtest clock gate. Mailbox transport doubles use an
explicit internal Cluster backend adapter; production Store has no mailbox fallback.

Final checkpoint: pre-commit passed formatting, warnings-as-errors compilation
and the full default suite: 1,174 tests, zero failures, three excluded large tests.
The known formatter trailing-comma disagreement stopped an initial attempt before
compilation/tests; applying its requested comma resolved it. Only one full suite
ran. No deployment or production verification was performed.

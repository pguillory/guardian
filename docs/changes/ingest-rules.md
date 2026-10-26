# ingest-rules: SET, UNSET, TRACK and LOOKUP rules stored as files

Status: complete through C4c3. SET/UNSET and TRACK/LOOKUP are live through normal
rule writes, startup, reload and HTTP/MCP ingestion. C1 provides node-local ETS,
C2 bounded cluster ownership, C3 mergeable operators, and C4 grammar, validation,
coherent activation, execution, memory configuration and product documentation.
The settled design and implementation history are below. Deployment is separate.
The phase 1 open questions were settled on the recommendations below.
Each was first kept switchable through app env (`:rules_on_failure`,
`:rules_invalid_at_boot`); once confirmed, the switches and the alternatives they
selected were removed. Rollout to a deployment is separate.

This document records the original phase designs, decisions and validation, not a
second current contract. Current behavior lives in
[spec section 5.1](../product/spec.md#51-rules); examples and store setup are in the
[rules guide](../guides/rules.md). The [Rules instructions](../../lib/guardian/rules/CLAUDE.md#rules-to-keep)
hold mandatory implementation invariants, and the
[rules architecture](../architecture/system.md#34-rules) describes the current
mechanism. The historical C1–C4 plans below retain their original contracts, with
supersession notes where later changes replaced them.

## Problem

Guardian stores events exactly as they arrive. A producer that wants a derived field
(a severity, a normalized email, an `is_blocked` decision) has to compute it before
sending, and a field that must never be stored (a password, a debug payload) has to
be stripped by every producer. Guardian once had a rule engine that did this at
ingest time (removed in 2026-09 with PostgreSQL and Memcached); this brings back its
stateless half without any of those services. Rules are plain files, so they can be
reviewed, diffed and backed up like code.

## Behavior after the change

### Rule files

1. Rules are files named `<table>/<name>.gsql`. The folder names the table the rules
   apply to; `<name>` is a label (`[a-z0-9_][a-z0-9_-]*`, at most 64 bytes). The
   table must be a valid Guardian table name. Built-in table names were once refused;
   since 2026-10-25 they take rules like any other table
   (`docs/changes/rules-builtin-tables.md`).
2. A file holds one or more statements separated by `;`, with `--` comments, at most
   64 KiB. Limits on the whole set: 1,000 files, 256 tables with rules, 1,000
   statements per table.
3. Phase 1 statements:

   ```sql
   SET severity = 'high'
   SET severity = 'high' WHERE status >= 500
   UNSET password
   UNSET debug_payload WHERE env = 'prod'
   ```

   `SET field = expr [WHERE cond]` sets a field. `UNSET field [WHERE cond]` removes
   one. Expressions and conditions are the query language's scalar expressions (all
   scalar functions, operators, CASE). Aggregates are rejected anywhere in a
   statement, WHERE included.
4. Counter v1 adds these forms:

   ```sql
   TRACK logins_last_hour = count() BY ip LAST '1h'
   TRACK spend_today = sum(amount) BY user_id WHERE status = 'ok' LAST '1d'
   LOOKUP prior_logins = logins_last_hour BY ip
   LOOKUP user_spend = spend_today FROM transactions BY buyer_id WHERE amount > 100
   ```

### Grammar

```text
rule_file   := [statement] (';' [statement])*
statement   := set | unset                        -- phase 1
             | track | lookup                     -- counter v1
set         := SET field '=' expr [WHERE expr]
unset       := UNSET path [WHERE expr]
track       := TRACK name '=' aggregate_call [BY expr (',' expr)*] [WHERE expr] LAST string
lookup      := LOOKUP field '=' counter_name [FROM table] [BY expr (',' expr)*] [WHERE expr]
field       := identifier without dots
path        := identifier, dots allowed, no list boundaries ('..')
```

1. `SET`, `UNSET`, `TRACK`, `LOOKUP` and `LAST` are recognized only by position in
   the rule parser, not added as tokenizer keywords. Adding keywords would make
   them reserved table names and break queries that use `set` or `last` as column
   names. `WHERE`, `BY` and `FROM` are already keywords. The expression parser
   returns at a token it cannot continue with, so `LAST` ends a TRACK's WHERE or BY
   (tests pin `SET set = last`, `UNSET last`, and that LAST is never read as an
   alias).
2. The rule parser is a new entry point (`parse_rules`) beside the query parser,
   sharing its tokenizer and expression parser. A query cannot contain a rule
   statement and a rule file cannot contain a query.
3. One field per statement; there is no `SET a = 1, b = 2`.
4. Identifiers are lowercased by the tokenizer, as in queries, so `SET Severity`
   defines `severity`.

### Semantics

1. Rules run on each event sent through `/api/json/send_events` or MCP
   `send_events`: the event is flattened and its invalid values dropped as today,
   then the rules run on that row, then the values the rules produced are validated
   the same way (one that cannot be stored is dropped), then the row is stored.
   Rules run on API-ingested rows, on any table; Guardian's own writes to its
   built-in tables never run rules.
2. Reads: a field the event lacks is null, with no warning. There is no declared
   schema and no check that a field exists. Rules see the flattened row, so an
   object field has no value of its own (`card` is null when the event has
   `card.number`); read the leaf (`card.number`). Names match ignoring case: an
   exact match wins, otherwise the first case-insensitive match in byte order. This
   differs from queries, which reject an ambiguous name, because a rule must give
   every event a result.
3. `SET x` replaces the whole incoming field: it first removes every column whose
   top-level field matches `x` ignoring case (`x`, `X`, `x.*`, `x..*`), then stores
   the new value as `x`. So `SET email = lower(email)` on `{"Email": "A@B"}` stores
   only `email`, and `SET user = 'redacted'` on `{"user": {"name": "Bob"}}` stores
   only `user`.
4. `UNSET p` removes every column matching the path `p` ignoring case, and every
   column beneath it (`UNSET password` removes `password`, `Password` and
   `password.hash`).
5. `WHERE` applies the statement only when it evaluates to true; false or null
   leaves the field as the event sent it.
6. Order within a table: every SET runs before every UNSET, so a SET can read a field
   that an UNSET removes (`SET has_card = card_number IS NOT NULL; UNSET
   card_number`). SETs run in dependency order (reads in the value and in WHERE
   both count): one that reads a field another SET writes runs after it.
   Independent statements are grouped into dependency levels, with file-name then
   statement order within each level. A SET that reads
   its own field reads the incoming value (`SET email = lower(email)`), and runs
   once however many files contain it.
7. Rules run in a short-lived worker process with the query heap limit
   (`GUARDIAN_QUERY_MAX_HEAP_MB`), not in the request process (MCP calls share one
   Anubis server process). The worker takes a batch's events in order and sends
   each event's rule result back as it finishes; the request process stores it.
   Each event has a 1 s rule time limit. If the worker exceeds that or its heap
   limit, or dies, that event fails, and a new worker continues with the next one,
   so every event gets its own ordered outcome. Query functions keep their own
   bounds (regular-expression backtracking limits, `replace`'s size handling).
8. A statement that raises, or an event over its time or heap limit: see open
   question 1. The worker catches its own raises; its log line names the rule file
   and line (for a raise) or the table and limit (for a kill) and the failure's
   kind, never a value, at most once a minute per file and node. Heap kills are
   reported without the error_logger report, so no crash report carries an event's
   values.
9. A reload while a batch runs may apply new rules to its later events; each event
   sees one consistent rule set.
10. SET and UNSET have no external calls or state. Counter v1 adds ephemeral state
    on Guardian nodes, with bounded peer calls and fail-open counter operations
    (see the counter design below). It adds no external runtime service.
11. Counter availability failures never reject an event. This exception does not
    relax SET/UNSET failure handling or skip UNSETs, including secret removal.

### Validation

Every write validates the whole rule set, all tables together. A write is rejected
if it adds an error the stored set did not already have (errors compared by file,
kind and message, ignoring line and column, so an edit that only moves lines does
not make an old error new). Deletes follow the same rule; in phase 1 a delete can
never add an error, and later deleting a TRACK a LOOKUP uses is rejected by it. So a set already broken (a hand
edit, or an upgrade that dropped a function used in two files) can be repaired one
file at a time, and an error in one table does not block writes to another. Every
result lists the errors that remain. Errors, each naming the file and line:

1. a file fails to parse, uses an unknown function, or uses an aggregate;
2. a file path is invalid (table name or file name) or a limit is exceeded;
3. a field on one table is defined two different ways: any two statements on the
   same field (two SETs, a SET and an UNSET, or two UNSETs of one path) that differ
   once parsed and unparsed
   (`to_source`, so whitespace, comments and keyword case do not matter; literals
   and WHERE do). Identical duplicates are one definition. Conditional alternatives
   go in one statement with CASE or `if()`;
4. SET statements on one table form a cycle (`SET a = b; SET b = a`). A self-read is
   not a cycle.
5. Counter v1: a LOOKUP must resolve to a TRACK of that name on its own table or
   its FROM table, with the same number of BY expressions. Deleting a referenced
   TRACK is rejected. TRACK and LOOKUP both define fields in the same namespace as
   SET. Their expression dependencies join the field graph, with the phase
   restrictions in the counter design below.

A stored set can still turn out invalid (a hand edit of the store, a build that
removes a function, or the lock race below). Loading handles that per table (see
"Loading"), and operators can always also edit the files in the store directly.

### Ingest response

The ingest APIs already take `return_keys`; this was how the old rule engine
returned computed fields, and it carries over. Rules run before the response is
built, so a requested field reflects them:

```json
{"table": "logins", "events": [{"ip": "203.0.113.9", "signal": 0.97}],
 "return_keys": ["is_blocked"]}
```

```json
{"status": 200, "results": [{"success": true, "event": {"is_blocked": true}}]}
```

1. A requested key the stored event lacks now comes back as `null` instead of being
   left out, so a client can always read it. This changes today's responses (keys
   used to be omitted); the spec and API reference call it out.
2. The reported event is built from the row after rules: Engine's current shortcut
   (report the original event when nothing was dropped) applies only when the rules
   changed nothing. Omitted or null `return_keys` returns the stored event,
   including computed fields and without unset ones.
3. HTTP and MCP share this through `Guardian.Web.Ingest`.

### MCP tools

1. `list_rules` (optional `table`): each file's table, name and size.
2. `read_rule` (`table`, `name`): the file's source.
3. `write_rule` (`table`, `name`, `source`): creates or replaces a file.
4. `delete_rule` (`table`, `name`).

Results distinguish: rejected (every validation message, nothing saved); saved and
every node reloaded; saved but some nodes not yet confirmed (named; they catch up by
polling); and failed or unknown storage outcomes ("may have been saved; list to
check"). Writes are logged (table, name, outcome; never the source). There are no
JSON API rule endpoints in phase 1.

### Storage of rule files

1. Two backends behind one interface (list with ETags, get bound to an ETag,
   conditional put, delete):
   - Local folder (default): `GUARDIAN_RULES_DIR`, defaulting to
     `$GUARDIAN_DATA_DIR/rules`. Writes go to a temporary file and are renamed. The
     ETag is a hash of the content.
   - S3-compatible bucket (R2): on when `GUARDIAN_RULES_S3_BUCKET` is set, with
     `GUARDIAN_RULES_S3_ENDPOINT` (`https://`, or `http://` only for `localhost`,
     127.0.0.0/8 or `[::1]`), `GUARDIAN_RULES_S3_ACCESS_KEY_ID`,
     `GUARDIAN_RULES_S3_SECRET_ACCESS_KEY`, optional `GUARDIAN_RULES_S3_REGION`
     (default `auto`) and `GUARDIAN_RULES_S3_PREFIX`. Setting both a folder and a
     bucket, or only some of the bucket settings, refuses startup.
2. No index or manifest object and no local cache. Each object is one rule file;
   listing the bucket (prefix-scoped) is the index. Objects not ending in `.gsql`
   are ignored (the write lock below is one); a `.gsql` object at an invalid path
   is a validation error for its table. A local folder is read the same way
   (`docs/changes/object-store-local.md`).
3. Reading the set: list, then GET each object with `If-Match` on its listed ETag;
   a mismatch (changed between list and get) restarts the read, at most 3 times.
4. S3 client (the generic `Guardian.ObjectStore.S3`, which Rules uses;
   `docs/changes/object-store-lock.md`): Req with its built-in SigV4 signing (`aws_sigv4`, `service: :s3`,
   region `auto` for R2) and `:xmerl` (added to the release) for ListObjectsV2 with
   pagination. Req is one new dependency; Finch and Mint are already in the lock
   through anubis_mcp. Connect and receive timeouts 5 s and 15 s, TLS verification
   on, listed sizes checked against the 64 KiB limit before any GET.
5. Credentials stay out of logs, error messages and process crash reports. The
   config holds them in a zero-arity function; store calls run inside a wrapper
   that catches everything and returns a safe kind (HTTP status, `timeout`,
   `connect_failed`), so a `Req.Request` never appears in a raised exception. A test
   forces failures and checks the captured log for the secret. As security.md
   already says of every secret, a VM crash dump still contains them.

### Loading

1. Startup loads the rule set before anything else (Rules is the first child,
   ahead of Storage's segment loading, so a bad store fails in seconds). An
   unreachable or rate-limited (HTTP 429) store is retried with backoff for up to
   60 s, then refuses startup. A 429 on a save or delete means nothing was saved.
   A misconfigured store (partial settings, bad credentials, missing bucket)
   refuses startup at once. Errors name the cause, never a credential.
2. A stored table whose rules fail validation at startup: see open question 2.
   A running node instead keeps that table's previous good rules after a bad
   reload, so a node restarting into a bad set and a running one can differ until
   the set is fixed.
3. Reload and poll never replace good rules with bad: all changed tables compile
   before one map is published; a failure keeps the previous set and logs.
4. If the Rules process restarts while Guardian runs, it keeps serving the
   published set (it lives in `:persistent_term`, not the process) and reloads in
   the background, so a store outage cannot take the rest of Guardian down.

### Writes, locking and reload

1. The cluster-wide lock is an object in the store, `_write.lock`, not an Erlang
   lock. It is the object-store client's generic lease lock on a key
   (`Guardian.ObjectStore.Lock`, `docs/changes/object-store-lock.md`), which Rules
   uses with this key and lease. Being an object, it also holds across a network
   partition (two sides with `:global` would each get one). Its body names the holder (node and a random token); the
   lease is 120 s from the object's `Last-Modified`, judged against the store's own
   `Date` response header, so the lease is measured on the store's clock and node
   clock skew does not matter. A writer creates it with `If-None-Match: *`. On 412 it
   reads the lock: a released or expired lock is taken over with `If-Match` on the
   ETag it read; a live one is retried for up to 10 s, then the write fails with
   "another rule write is in progress". The local folder uses the same scheme with
   an exclusive create and rename.
2. Under the lock the writer reads the whole set from the store (not memory),
   applies its change, and validates (above).
3. It saves the one file (PUT, or DELETE), only if at least 80 s of its lease
   remain, and with an overall 20 s deadline on that request (connect plus
   response). So a save that completes lands well inside the lease.
4. Release is ownership-safe: the writer overwrites the lock with a "released" body
   using `If-Match` on its own lock's ETag (S3 has no conditional delete), so it can
   never release a successor's lock. If the save's outcome is unknown (deadline,
   connection lost), the writer does not release: the lock stays held until its
   lease expires, so the next writer starts at least 60 s after the uncertain
   request was abandoned, and validates against whatever it finds.
5. It then tells every connected node (itself included) to reload and waits up to
   10 s. Nodes reload from the store, reading only objects whose ETag changed.
6. With the local-folder backend and other nodes connected, writes are rejected:
   each node has its own folder, so a cluster needs the bucket. A single machine
   works with either.
7. Every node lists the store every 60 s and reloads when any ETag differs, to
   catch a reload it missed. A failed poll keeps the current rules and logs at most
   once every 10 minutes. One LIST a minute is about 45,000 class A operations a
   month per node.
8. What this does not guarantee: S3 cannot make one object's write conditional on
   another, so without a commit object (ruled out: no manifest) no lock can fence a
   writer that stalls past its lease after the 80 s check, or a request the store
   applies more than 60 s after the writer abandoned it. Either can leave a set
   that validation would have rejected; loading handles it per table, and the
   next write reports it. See open question 3.

### Compilation

1. The design used fixed templates and escaped AST data, with regular expressions
   held as pattern strings, never compiled `:re` references. Native code generation
   per expression was left as a later optimization. The current compiler shape is in
   [architecture section 3.4, item 2](../architecture/system.md#34-rules).
2. The original pool sizing allowed two generations of the table limit plus
   reclamation slack. Bounded atoms and immutable module names are maintained by
   [Rules invariants 2–3](../../lib/guardian/rules/CLAUDE.md#rules-to-keep).
3. Publication and compile-failure rollback follow
   [Rules invariant 2](../../lib/guardian/rules/CLAUDE.md#rules-to-keep) and
   [architecture section 3.4, item 3](../architecture/system.md#34-rules).
4. Reclamation's grace period and soft-purge mechanism are described in that same
   architecture item; the prohibition on forced purge is Rules invariant 2.
5. Restart recovery and pool reconstruction are also described in architecture
   section 3.4, item 3. Loaded names outside the published map are retired rather
   than freed, so a restart cannot reuse a name still callable by an old worker.
6. Counter v1 extended activation to dependent LOOKUP plans in C4b/C4c1, enabled
   in C4c3 below. Current coherent reload requirements are
   [Rules invariant 11](../../lib/guardian/rules/CLAUDE.md#rules-to-keep).
7. Running a statement does not scan the row. At the first statement the runtime
   indexes the event's flattened row once: a trie of its keys by lowercase
   top-level object path, and each lowercase spelling's present keys in byte order.
   SET and UNSET then remove one subtree and a read is a lookup, so 1,000 statements
   on an event with 100,000 columns cost about the columns once, not their product.
   The trie is built at the first statement that applies, since it decodes every
   key, so an event whose statements all skip decodes none. (The first build scanned
   every key per applied SET and UNSET, and a read without an exact key walked that
   name's case variants, removed ones included.)

## TRACK and LOOKUP: settled v1 design and implementation plan

This extends the completed SET/UNSET work. The implementation has four pieces,
C1 through C4; C4 is split into sequential commits below. C2 and C3 depend on C1;
C4 depends on both. The grammar
above stays unchanged. There is no Memcached, sidecar, counter persistence, backfill,
hot-key sharding or replication. Separate best-effort same-node idempotency-key
receipts can skip completed retries; this is not cluster-wide deduplication.

### Counter behavior

Execution now batches dependency levels and key state machines through concurrent
owner pipelines; see [counter-batching.md](counter-batching.md). Independent
statements share levels; scalar work finishes before counter dispatch, including
when an event later fails. Counter results, LOOKUP barriers and failure defaults
below remain unchanged.

1. TRACK updates its named counter and writes the resolved window value into the
   event under that name. A successful update includes the current event: the
   50th login sees 50. LOOKUP only reads, writes under its own field name, and can
   name a counter on another table using FROM. Query execution reads the recorded
   event fields, never live counters.
2. Every LOOKUP on an event completes its counter reads before any of that
   event's TRACK updates. Thus a LOOKUP of the same counter excludes that event,
   independent of file or statement order. This is a per-event barrier, not a
   global snapshot: other events may update between individual reads.
3. BY expressions make an exact ordered tuple of typed values; omitted BY is the
   empty tuple (one global group for that counter). Null components are valid and
   share a null group; strings and numbers remain distinct. Hashing uses a stable
   encoding of that tuple, never atoms created from input. Integer 1 and float 1.0
   are distinct keys; cross-table LOOKUPs need matching types as well as values.
   LOOKUP supplies its own values and must match the TRACK's grouping arity.
4. WHERE false or null skips the statement, preserves its incoming output field,
   and for TRACK does not update. A missing/expired bucket supplies the aggregate's
   empty state. Missing results are 0 for count and count distinct, and null for
   sum, min, max and avg. A skipped value is not a store failure.
5. Scalar expressions keep existing total-function behavior. count() counts every
   matching event; count(expr) counts non-null values; count_distinct(expr) uses
   HyperLogLog at precision 8. Sum and avg skip non-numeric values; min and max use
   the query engine's ordering and skip nulls. Numeric wrapping/overflow follows
   existing query aggregates. Approximation and loss can also make counts lower.
6. A failed counter read or update writes the aggregate's missing result into its
   output field and continues the other rules. It never preserves an untrusted
   incoming counter value as if a read had succeeded. A statement skipped by WHERE
   still preserves its field. There are no event retries or rollback: a client
   resubmission counts again, and a later rule/storage failure can leave an earlier
   TRACK update counted. Completed matching same-node keyed retries skip rules,
   returning only a receipt, without counter/decision values; the protection is
   short-lived and can be lost (see `ingest-idempotency.md`).

### Time buckets and identity

1. Record a private arrival time once per event in Guardian.Engine.ingest_events before
   rule execution, carried as metadata outside the row. Caller fields and SETs
   cannot supply or overwrite it. Use Unix milliseconds for bucket coordinates
   shared between nodes; use monotonic time for local deadlines and TTLs. Every
   counter on the event uses that same arrival time. Node clock synchronization
   remains an operator responsibility; there is no event-time or late-event mode.
2. LAST is a positive integral interval in the existing interval-string form
   (`s`, `m`, `h`, `d`, `w`), bounded to 365 days. In milliseconds let W be the
   window and B = ceil(W / 3). Write only bucket floor(arrival / B).
3. Read buckets floor((arrival - W) / B) through floor(arrival / B), inclusive:
   at most four reads, including the current bucket. Choose overcount at the
   boundary: keep all of the oldest intersecting bucket, including events up to
   B milliseconds older than the requested window. No proportional weighting.
   For a 30-minute window, B is 10 minutes and the value can include almost
   40 minutes. This describes bucket bias, not a guaranteed numeric upper bound:
   sum may be negative, HyperLogLog is approximate, and eviction/loss undercounts.
4. Each bucket expires at bucket_end + W. Compute a positive remaining TTL from
   that fixed expiry when issuing a write; do not extend retention by a fresh
   full window on each update. If the expiry has already passed, omit the update
   and use the missing result rather than inventing a positive TTL. An unchanged
   state skips its write and does not refresh TTL. Old definition keys disappear
   by TTL or eviction.
5. Identity is {table, counter name, SHA-256(canonical TRACK source)}. Canonical
   source is parsed/unparsed, ignoring file, line, whitespace and comments, but
   including aggregate, expressions, WHERE and LAST. A semantic edit or rename
   starts fresh; moving an identical definition between files does not.
6. Store key is {counter identity, typed group tuple, bucket number}. Owner routing
   hashes only {counter identity, group tuple}, so all window buckets share an
   owner. Compiled LOOKUPs carry their target TRACK's resolved definition hash.

### C1: node-local key-value store

The original C1 implementation contract below is historical. The direct public
ETS implementation, fixed insertion expiry, asynchronous memory target and
sampled expiry-cutoff eviction supersede it in [counter-store.md](counter-store.md).

Build `Guardian.Counters.Store`, an independently supervised GenServer owning private ETS
tables: a key/value set, an insertion-order index, and an expiry index. The
process serializes operations, making increments and CAS atomic without exposing
ETS or adding a library/service. Start it after Guardian.Rules.Server and before Storage;
rule loading does not touch counters. A store restart clears only counters.

Contract (server defaults to Guardian.Counters.Store, tests may use an unnamed PID):

```text
get(key, opts)                     -> {:ok, value} | :not_found | {:error, reason}
gets(key, opts)                    -> {:ok, value, token} | :not_found | {:error, reason}
cas(key, expected, value, ttl_ms, opts)
                                  -> :ok | {:error, :conflict | reason}
incr(key, delta, ttl_ms, opts)      -> {:ok, new_integer} | {:error, reason}
```

1. `expected = :missing` creates only an absent/expired key. A token is opaque and
   unique for every successful mutation, including increments; never reusable
   after expiry, eviction, recreation or a process restart. Stale CAS conflicts;
   it never recreates an absent key. incr creates an absent key with delta and
   rejects an existing non-integer. Increments are unbounded store integers;
   aggregate resolution applies the storage-safe numeric policy.
2. TTL is a positive integer in milliseconds and starts when a mutation executes.
   Successful mutations replace the TTL; reads and conflicts do not refresh it.
   Expiry is checked before every access; a periodic, bounded sweep reclaims quiet
   expired keys, continuing immediately while more are due. Replacing a value
   removes its previous expiry entry. Creation
   time/order survives updates; eviction is FIFO, not LRU.
3. Default memory budget: 64 MiB per node, overridable through app env
   `:counter_memory_budget_bytes` and the start option `:memory_budget_bytes`.
   Charge ETS table memory plus the serialized size of keys/values to include
   off-heap binaries conservatively, including larger backing allocations retained
   by slices anywhere in keys/values (shared backing/inline data may be counted
   more than once). The
   budget covers resident counter entries/indexes, not process mailboxes, temporary
   copies, the rest of the VM or fixed empty-table overhead.
4. On reaching the budget, reclaim all expired keys before removing roughly the
   oldest half of live keys if still necessary. If unusually
   large survivors still exceed it, repeat; a value too large to fit alone is
   refused as `:too_large`. Eviction is deliberately crude and can lose live
   counts. If the updated key itself is among the oldest keys evicted, return
   `{:error, :evicted}`: definite counter loss, not an uncertain RPC outcome.
   `:too_large` is also a definite failure: the up-front payload check preserves
   existing keys, but a value that fits that check and exceeds capacity with ETS
   overhead can lose its previous value and evict other keys before being removed.
   Expose aggregate stats for tests/diagnostics, never keys or values.
   Ordinary key access does not scan the store; bulk eviction is the exceptional
   capacity path and can stall the single store process. C2's timeout/cooldown
   covers that stall. Expiry sweeping works in bounded batches through its index.
   This single process serializes all local traffic; sharding is deferred.
5. Calls default to a 50 ms timeout, return a scrubbed error for timeout/dead store,
   and carry a local monotonic deadline checked before executing a queued request.
   A timeout after a mutation began is an uncertain outcome, never retried as an
   increment. Timed-out requests not yet begun must not mutate later.
6. Malformed requests return errors without crashing the owner. Formatted status
   and failure logs must not disclose keys/values. Tests cover misses versus a
   stored nil, TTL boundaries and renewal, quiet expiry, CAS conflicts, absent-key
   races, ABA across expiry/eviction/restart, exact concurrent increments,
   budget/oldest-half behavior, large binaries, and unavailable/expired requests.

C1 changes no rule syntax or current user-visible rule behavior. Product spec
impact: none. Update the system supervision/store description, subsystem guidance,
the change status and TODO. Runtime configuration documentation can describe this
internal app setting; the user-facing environment setting belongs to C4.

### C2: counter ownership and bounded cluster operations

The original single-call client described below was superseded by owner pipelines
in [counter-batching.md](counter-batching.md) and removed in
[counter-retirement.md](counter-retirement.md). The later split into Client,
Transport and Budget is described in [counter-client.md](counter-client.md).
Native values, tokens and budgets retain the same contract through the batched endpoint.

Implemented as `Guardian.Counters.Cluster`. Product spec impact: none; no statements are
enabled until C4. `new_batch/0` provides a shared atomics failure budget kept outside
replaceable workers; `new_event/2` captures membership and starts a conservative
100 ms wall-clock counter phase. Each operation atomically reserves its allowance,
refunds successful calls completely (including misses/CAS conflict), and charges
actual failed wait up to that reservation. Caller death retains the outstanding
reservation, preserving the bound across replacement. The 100 ms wall-clock phase
also charges time between calls, deliberately stricter than call-time accounting.
Owner routing now uses `:erlang.phash2/2` directly, replacing the custom typed encoder
and SHA-256 score. phash2 accepts any term and distinguishes integers from floats;
signed zeros share an owner but remain distinct stored counters
through Store's ETF keys. Remote endpoints preserve native values/reference tokens,
and guard/worker cleanup bounds flow-control stalls and discards late replies.
Mixed-version peers without the endpoint fail open. C1 expiry throughput and
supervisor crash isolation were completed as the separate C4 runtime prerequisite below.

Build `Guardian.Counters.Cluster` over C1. Use rendezvous hashing (consistent ownership when
members change), selecting the highest score
`{:erlang.phash2({routing_key, member_name}, 4_294_967_296), member_name}` where
`routing_key = {identity, group}` excludes the bucket and member_name is the node's
string name, breaking hash ties. Capture the member list once per event from this
node and its connected peers. Do not call
`Guardian.Cluster.connected_nodes/0` on the ingest path: its storage-readiness RPCs can wait
5 seconds. A booting/unavailable owner fails open like any other failure.

1. All C1 operations route to the selected owner's local store. Support fetching
   the up-to-four bucket keys in one bounded owner request where practical; the
   local store contract remains usable for each key. Never route remote work back
   through another routing layer. Preserve native terms and CAS tokens over RPC.
2. Default operation deadline is 50 ms. C4 shares one 100 ms counter budget across
   the event and one 250 ms failed-counter-wait budget across the whole ingest
   batch, below the existing 1-second per-event rule limit. Every call spends the
   event budget; only time spent in calls that fail, time out or have uncertain
   outcomes spends the batch budget. Successful healthy calls do not spend the
   batch budget, so large healthy batches keep counting every event. Each request
   uses the smaller remaining budget. The batch budget survives rule-worker
   replacement. Once exhausted, later counter statements use missing results
   without waiting for the store. Do not issue a call with less than 10 ms
   remaining; use the missing result without marking the owner suspect.
   A remote endpoint translates a remaining
   duration into its own monotonic deadline, rather than comparing monotonic
   timestamps from different VMs. Avoid RPC paths that wait synchronously for
   distribution flow control past the deadline; bound the caller with a helper
   process where needed and leave no lingering caller helper. Transit time before
   the remote endpoint sees a request is not covered by its local deadline, and
   killing the caller helper cannot cancel an already-dispatched remote mutation.
   Such uncertain late writes are accepted and never retried.
3. After a timeout or uncertain/unavailable operation, mark that owner suspect in
   a small node-local cooldown map for one second. During cooldown, including for
   the local store, fail immediately instead of accumulating more queued calls.
   A timeout marks an owner suspect only if that call had at least a 25 ms
   allowance; a tiny remaining event budget must not cause a node-wide cooldown
   of an otherwise healthy owner. Local eviction stalls may therefore suspend
   all counter operations routed to that store for a second, by design.
   This state is independent of the counter store, keyed only by current members,
   and expires/cleans up without growing with user group keys. No retries onto
   another node, state migration, replication, readiness round trips
   or recovery protocol. Membership changes may lose counts and split membership
   views may create divergent state. An uncertain increment is never retried.
   Partitions must not block ingest; perfect partition semantics are deferred.
4. Test deterministic/order-independent ownership, small membership changes,
   same-group bucket colocation, native remote get/gets/cas/incr, peer loss, slow
   and booting owners, short elapsed time, cooldown/recovery, and no helper/message
   leaks. Test a long batch against a frozen peer and an overloaded/evicting local
   owner: failed counter wait stays within the fixed batch budget, rather than
   growing with event count. Also test large batches against healthy local and
   peer owners: every event is counted and successful call time never exhausts the
   batch budget. Use only
   local test peers. Document the availability/precision tradeoff and trust
   boundary. Product spec impact: none until statements are enabled in C4.

### C3: mergeable aggregate operators

Superseded in part by [aggregates-unify.md](aggregates-unify.md): the counter
allowlist, the separate counter configurations (int64 count finishing, the p14
query sketch, the counter-only average shortcuts) and sum's distinct query default
are gone; every aggregate is a counter operator with the query configuration. The
history below is unchanged.

Implemented first as a pure counter operator API with no store or rule wiring;
shared per-aggregate implementations and resolved plan configurations now own it
([shared-aggregates.md](shared-aggregates.md),
[counter-retirement.md](counter-retirement.md)). Its own product spec impact was
none; C4c3 enables TRACK/LOOKUP. Operators are `{string_name, arity}` tuples from
`Guardian.Aggregation.counter_operators/0`. `start/2` takes a resolved configuration
and one event's list of arguments. Callers compare merged states with the prior state
using `===` before deciding whether to write; all count states, including native
increment results, pass through `finish/2` for int64 output bounds.

Empty sum is nil (unlike query sum's 0.0), empty average is `{0, 0}`, and empty
distinct is a Hypex precision-8 sketch using fixed 256-byte bitstring registers in
the pinned library. Average preserves exact integer sums, ignores empty states
without changing signed zero, and weights merged buckets by count. Min/max retain
query ordering and right-biased ties, including the winning numeric type. Integer
sum wrapping and absorbing float overflow match query aggregates. Floating-point
rounding and cancellation, overflow, and mixed integer wrapping mean regrouping
can change a numeric result. Query aggregates and their precision-14 distinct
sketches are unchanged. Historical aggregate sharing was subsequently completed
in [shared-aggregates.md](shared-aggregates.md), preserving these contracts.

Counter aggregation is independent of query execution, using the shared API:
`start(configuration, values)`, `merge(configuration, left, right)`,
`finish(configuration, state)`, and `empty(configuration)` (a mergeable state).
Finishing the empty state supplies the documented missing result. Operators are a fixed
allowlist: count/0, count/1, count_distinct/1, sum/1, min/1, max/1, avg/1.

1. Count uses an integer; avg keeps {sum, count}; distinct keeps a bounded Hypex
   precision-8 sketch. Skip writes when merging leaves state unchanged. Share
   existing numeric and ordering helpers where correct, but do not alter query
   GROUP BY behavior or its precision-14 distinct implementation in this piece.
2. C4 uses one incr for ordinary count, and gets/create/merge/cas for other
   aggregates. A missing key uses CAS with :missing, never unconditional overwrite.
   Retry only definitive CAS conflicts, at most three attempts and within the
   event deadline; drop the update on exhaustion. Do not retry RPC failures or
   uncertain outcomes. Merge states across window buckets, then resolve once.
3. Test empty states, null/mixed values, merge identity and associativity within
   floating-point tolerance, partitioned merging, numeric overflow, avg weighting,
   HLL fixed precision/size and cardinality error, and unchanged-state detection.
   Product spec impact: none until C4. Historical aggregate sharing was follow-up,
   since completed in [shared-aggregates.md](shared-aggregates.md).

### C4: rule integration and product behavior

C4 was split into C4a/b/c. C4a added contextual TRACK/LOOKUP AST parsing,
canonical source and source-order traversal, with an explicit RuleSet refusal
before executable steps were built. Its product spec impact was none: active rules
then supported only SET/UNSET. Canonical source normalizes count(*) to count(), just as
the query parser does. The syntax parser currently uses the query aggregate
registry/arity checks. C4b now validates the counter allowlist, scalar
arguments/BY/WHERE, interval bounds and FROM table validity. Dependency reads come
from input clauses, not whole-statement traversal (which also visits names).

Implemented: the C4b prerequisite separates typed SET/UNSET steps, scalar checks
and field dependency ordering from RuleSet orchestration. It preserves validation
errors, execution order and counter refusal. Product spec impact: none.

C4b implemented: internal `Guardian.Rules.RuleSet.prepare/1` returns locally valid unbound
candidates plus whole-set resolved plans. It validates the `Guardian.Aggregation` counter
allowlist, scalar clauses (including nested aggregate refusal), positive integral
LAST totals through the existing s/m/h/d/w interval parser, the 365-day bound,
FROM tables, TRACK targets and grouping arity. Signed/compound interval terms
retain the existing parser's semantics; the final total must be positive.
Identical canonical definitions deduplicate, all output kinds share one field
namespace, self-reads use incoming fields, and UNSETs remain last. LOOKUPs and
their prerequisite SETs run before remaining SETs/TRACKs; a LOOKUP's input clauses
cannot depend transitively on a TRACK output. Target names add no field execution
edge, whether the target is on this table or another one.

TRACK identities hash only canonical source and carry table/name, while plan
hashes also include diagnostic locations and bound target definitions. Invalid
targets propagate to dependents to a fixed point with stable error details that
do not depend on a target's broken contents. Reciprocal cross-table references
are valid: resolution uses definition identities rather than target plan hashes.

`Guardian.Rules.Activation.select/2` is pure and accepts previous resolved plans. At runtime,
components are the undirected union of old bound LOOKUP edges and new locally valid
candidate edges. If any table is invalid, the whole component retains its previous
valid plans unchanged. This covers an invalid target with valid changed dependents
and an invalid dependent with a valid changed target. Deleting a table or TRACK in
a retained component is deferred too. Tables without a previous valid plan that
join a retained component are marked invalid, with a diagnostic naming the component cause, until a fully valid
reload can switch it together. Unrelated components activate normally. At boot,
with no previous plans, only directed target-invalidity propagation applies.

Plan review narrowed C4b to these tested pure preparation/selection contracts.
Server wiring and bounded recoverable plan metadata landed in C4c1 below;
C4c2 added internal execution, and C4c3 enables it with live reload/restart tests.
At the C4b checkpoint, public validation and Compiler still refused counters and
product spec impact was none. That temporary refusal is removed in C4c3.

Implementation order (all completed):

1. C4b, implemented: whole-set validation, dependency graph, resolved definition
   identities and pure coherent reload selection. Counter statements were still unavailable.
2. Prerequisite (C1 follow-ups), implemented: quiet expiry catches up in immediate
   pages and capacity reclaims expiry first; counter crash loops recover separately
   from Guardian.Application as described below.
3. C4c1, implemented: Server activation selection and bounded recoverable module
   metadata, with unresolved-plan safety. Product spec impact: none.
4. C4c2, implemented: internal execution, buckets, private arrival metadata and
   shared event/batch budgets, with both gates closed. Product spec impact: none.
5. C4c3, implemented: enable both gates together; live coherent counter reloads/restarts,
   HTTP/MCP return_keys and stored historical fields, runtime memory configuration,
   and the full user-visible documentation obligations below. Include stopped/slow
   peers, cooldown recovery, duplicate events and partial side effects in live
   coverage, building on C2's routing tests and C4c2's internal execution tests.

C4c1 connected boot, reload and saved writes to `Guardian.Rules.Activation.select/2`. At that checkpoint it used
`RuleSet.prepare/2` with `counters: false` everywhere on the live path. The public
unsupported-before-scalar precedence and Compiler's independent counter gate stayed
closed at that checkpoint. Local candidates have `resolved?: false`; successful whole-set resolution
marks plans resolved. Compiler rejects unresolved candidates before loading any
code, and independently rejects a LOOKUP with no bound target, even if its plan
is marked resolved.

Each generated module exposes its exact resolved `plan/0`, including canonical
source and AST literals, as escaped fixed-template data. Server derives previous
plans directly from published modules for selection, including after restart;
there is no separate metadata registry or hashes cache to drift from publication.
The existing module pool and rule limits bound metadata; discard/reclaim removes
metadata with code. Invalid stored copies retain previous good plans, unrelated
changes and valid deletions still activate, and compilation failure publishes
nothing. Preparation errors plus selected-table errors remain in logs and write
results; write admission compares only raw stored-set errors to keep repairs valid.
Formatted status redacts plans and bare steps, including expression constants.

Coverage includes candidate refusal without module creation, exact plan round-trip
with regex/scalar expressions, restart through invalid/unreachable stored copies,
repair and unrelated changes/deletions, atomic pool-exhaustion rollback, metadata
reclamation, and status redaction with secrets inside AST literals. Live counter
dependency-component reload/restart tests were left to C4c3; C4c1 did not bypass
the counter gates to simulate execution. Its overview and product spec stayed unchanged.

C4c2 implemented internal execution behind those same closed admission and compiler
gates. `Guardian.Rules.Runtime.run/3` dispatches ordered typed steps; tests drive it with
resolved `RuleSet.prepare/1` plans. There is no compiler bypass or public path
activating counters. Generated SET/UNSET modules use this dispatcher too and expose
`apply/2` for private metadata, with `apply/1` creating a fresh event/batch context.

Engine captures Unix and monotonic arrival coordinates before each event's
validation, outside caller rows. All events are prepared before the worker runs;
a later event can therefore reach rules after its window expired. Runner creates
one batch atomics handle outside replaceable workers and snapshots membership and
starts each event's bounded Cluster phase on worker entry. Arrival coordinates
survive replacement and are never automatically stored or modifiable by SET.

Counter execution (`Guardian.Counters.Execution`, formerly
`Guardian.Rules.CounterRuntime`) reads up to four complete intersecting buckets (the oldest
can overcount by almost one bucket). TRACK merges prior buckets with its own
mutation's returned state, without a read-back that could omit the current event.
Count uses one native increment; zero deltas read without mutation. Other operators
use gets/merge/CAS, skip unchanged states and retry only definite conflicts, at most
three total attempts within Cluster budgets. Any failed operation or exhausted
conflicts supplies the whole aggregate's missing result, never a partial total.
Counter expression exceptions also default; final UNSETs still run. SET/UNSET
exceptions retain their fail-closed behavior. There is no rollback or event retry.

Each mutation computes a positive remaining TTL against bucket_end+window, anchored
once to the event's private monotonic coordinates; an already expired update is
skipped and TRACK yields the missing result. TTLs are not renewed to a fresh full
window. Store receives remaining
durations, so transit and queue delay can still delay physical owner expiry.

C4c2 coverage includes 49/50 and LOOKUP-before-TRACK, cross-table typed/null groups,
all operators/defaults, WHERE preservation, SET dependencies, UNSET after failure,
definition edits/moves and duplicate TRACK deduplication, bucket boundaries,
expired-before-issue updates, no-op states, fixed TTLs, bounded CAS conflicts and
uncertain-write non-retry, healthy batches/concurrent increments, many-rule batch
budget exhaustion, worker replacement and private Engine metadata. Real enabled
reload/restart, API/MCP and full feature documentation were left to C4c3.

C4c3 enables the public path coherently: validate/1 and Server's shared helper use
counter-aware prepare/1, and Compiler admits resolved counter plans. The obsolete
disable option and early unsupported-statement branch are removed. Unresolved
candidates and unbound LOOKUPs still refuse compilation; there is no bypass or
second execution path. GUARDIAN_COUNTER_MEMORY_MB accepts positive integer MiB,
defaulting to Store's 64 MiB; explicitly empty/invalid configuration refuses boot.

Live tests use normal writes, FakeS3 reloads, generated modules, HTTP routers and
an MCP client. They cover valid target/dependent identity switches, retained old
modules continuing with old identities, definition moves, invalid target/dependent
retention across deletion/join/transitive/retarget cases, unrelated activation,
Guardian.Rules.Server restarts through invalid/unreachable stores and directed boot failure.
Public counter migrations test the add-new/retarget/delete sequence for incompatible
BY/name changes. API tests cover 49/50, SET-derived groups/decisions, copied TRACK
deduplication, forged caller timestamps, return_keys variants and historical fields
after definition edits and Store loss. Live aggregate and typed/null group tests
complement the existing exhaustive internal runtime cases.

Stopped/slow named local and real peer stores exercise aggregate defaults, bounded
long-batch waits, cooldown/recovery, restart resets and UNSET secret removal, with
serial tests restoring process availability/cooldowns. Concurrent healthy peer
events all count. Additional tests show unkeyed duplicates, cross-interface keyed
receipts, later rule/storage failures leaving increments, and status/log redaction.
The exact CAS/budget/worker/bucket/TTL boundary matrix remains in C2/C4c2 tests.
Live long-batch tests bound cooldown behavior; they do not claim to isolate the
250 ms allowance, which the lower-level tests exercise without cooldown masking.

C4c3 product impact: overview rules/state and removal of the counter non-feature;
spec section 1's ingestion commitment, section 5's private-arrival clarification,
5.1 syntax/order/defaults/failures/reloads, 10 ownership/loss and 11 non-features.
README, rules/cluster guides, HTTP/MCP reference and tool description, configuration,
limitations, architecture/security and applicable guidance describe the live feature.
Counters are advisory and ephemeral, not durable enforcement limits; UNSET does not
erase group/min/max data from counter memory. Deployment remains a separate action.

C4 runtime prerequisite implemented separately from rule integration: quiet expiry
uses 256-entry pages with immediate continuation while expired entries remain;
capacity pressure reclaims all expired entries before evicting live keys. Indexed
capacity reclamation, like existing bulk eviction, can outlast callers; the bounded
cluster operation/cooldown contract still applies.

Store and Cluster now run inside Guardian.Counters.Supervisor, owned by a trapping
Guardian.Counters.Restarter rather than directly under Guardian.Application. Local 3-in-5-second restart
exhaustion shuts down only counters. The owner logs a fixed error reason and retries
with capped exponential backoff, reset by a healthy stretch (timing is specified in
`docs/architecture/system.md` section 2.1).
Failed starts retry too; invalid Store options still refuse initial startup. The
owner never adopts a subtree with an old OTP parent. Orderly owner shutdown stops
its subtree synchronously, with no failure log. Regression tests cover backlog
catch-up, expiry before live eviction, child restart independence, crash-loop
isolation, automatic recovery/backoff/reset, failed/overlapping starts, stale timers
and clean shutdown after recovery. Product spec impact: section 8 adds the sampled
`system_stats.counters_available` boolean; overview unchanged, `/health` stays
Storage-only. TRACK/LOOKUP statements stayed unavailable until C4c3 enablement.

The complete C4 contract:

1. Add contextual TRACK/LOOKUP AST nodes, parsing and canonical source output.
   Validate aggregate name/arity, scalar inputs/BY/WHERE, LAST bounds, referenced
   definitions and grouping arity, field conflicts, identical TRACK deduplication
   (one increment even if copied into several files), and dependencies across all
   files/tables. Aggregates remain invalid in SET, WHERE and nested expressions.
2. Build the field dependency graph for SET/TRACK/LOOKUP, retaining self-reads of
   incoming fields. Reject cycles and any LOOKUP whose inputs or WHERE transitively
   depend on a TRACK output: that would require a TRACK before the LOOKUP barrier.
   Run LOOKUPs and their prerequisite SETs first, then remaining SETs/TRACKs in
   dependency levels, then all UNSETs. Independent order within a level stays deterministic. SETs
   can use TRACK results (for example a blocking decision) and TRACKs can use SET
   and LOOKUP results. All-SET/UNSET tables use the same dependency levels.
3. Capture arrival metadata and membership at event entry, bind target definition
   hashes into immutable compiled plans, and include those hashes in recompile
   dependencies. Old in-flight modules keep their old identities; publishing a
   changed TRACK and its LOOKUP dependents remains atomic per node. If an invalid
   reload retains a table's prior good plan, its whole old/new dependency component
   retains coherent prior plans as described in C4b above.
4. Complete every event's LOOKUP reads before TRACK writes; for a successful TRACK
   use the state returned by its own current-bucket mutation plus other buckets,
   so concurrent updates cannot make it omit its own event. No global atomic read
   of all buckets is promised. Bound all calls/CAS attempts by the shared event
   and failed-wait batch budgets, honoring the per-owner cooldown. On exhaustion
   later counter statements use missing results
   while SET/UNSET still execute, with existing failures remaining fail closed.
5. Add `GUARDIAN_COUNTER_MEMORY_MB` (positive integer, default 64) through runtime
   configuration, converting to C1's byte budget. Invalid explicit configuration
   refuses startup. Test config and document restarts, loss, boundary bias, duplicate
   submissions and the fact that counters are advisory rather than durable limits.
6. Product spec impact: overview's rule forms/state and counter non-feature;
   spec section 5.1 syntax, ordering, defaults, failure semantics and counters;
   section 5's private arrival metadata clarification (no automatic stored field);
   section 10's ownership/loss behavior, section 11's counter non-feature and
   section 1's formerly stateless-only ingestion commitment.
   Update rules/API/MCP references, the rules guide, architecture/security,
   limitations, configuration and applicable CLAUDE.md files together. Do not
   claim TRACK/LOOKUP are available in earlier pieces.
7. Test parser round trips/contextual names; rejected definitions/dependencies;
   statement-order independence; the 50th-event example and LOOKUP=49/TRACK=50;
   cross-table/group lookups; SET-derived groups and SET decisions from TRACK;
   WHERE skipping, null groups, all operators, bucket boundaries and expiry;
   forged caller timestamps; expired-before-issue writes; identical TRACK copies;
   edited-definition resets and coherent dependent invalid reloads;
   contention, stopped/slow stores and peers, budget exhaustion with many rules;
   bounded failed counter wait across long batches with stalled owners, healthy
   large batches counting every event, recovery after
   cooldown, UNSET secret removal after counter failure; duplicate events and partial
   side effects; HTTP/MCP return_keys and stored historical values. Keep all tests
   independent of external services.

### Review, checks and deferred work

Review this whole-feature plan independently with Claude and Codex before C1
implementation. Each piece then gets its own implementation checks and independent
Claude/Codex staged-diff review before its normal commit. Run mix format first,
warning-free test compilation, targeted tests, and the full suite/pre-commit checks
as documented in the development guide. No deployments, WIP commits, amend, rebase
or force push.

Deferred: persistent counters/recovery, backfill, stronger partition semantics,
hot-key sharding, cluster-wide idempotency,
and richer operators such as last-N lists. Record distinct follow-ups instead of
expanding the four pieces. Shared query aggregate implementations are completed
in [shared-aggregates.md](shared-aggregates.md).

## Phase 1 product spec impact (completed)

1. `overview.md`: replace "Guardian has no rule engine, alerting, or blocking" with
   ingest-time SET/UNSET rules stored as files; keep "no alerting".
2. `spec.md`: Purpose ("not transform events by rule"), a new section on rules
   (files, grammar, semantics, validation, storage, MCP tools), Ingestion (rules run
   before storage; `return_keys` returns null for missing keys), the MCP tool list,
   Non-features item 1 (rules exist; still no alerting, counters, or enrichment from
   services), configuration.
3. Also: `CLAUDE.md`, `lib/guardian/CLAUDE.md`, `lib/guardian/engine/CLAUDE.md`, `lib/guardian/ast/CLAUDE.md`,
   `lib/guardian/ast/node/CLAUDE.md` (LOOKUP line), `lib/guardian/web/CLAUDE.md`, `lib/guardian/web/mcp/CLAUDE.md`
   (drop "Do not add ... rule-management tools"), a new `lib/guardian/rules/CLAUDE.md`,
   `docs/architecture/system.md` (supervision tree, ingest path, a rules section),
   `docs/architecture/security.md` (rules can rewrite or drop any incoming field at
   the key holder's trust level; their cost on the ingest path; generated code from
   templates only; bounded atoms; S3 credentials in the secrets inventory with
   rotation: create a new token, update the settings, restart, revoke the old one;
   the lease race), `docs/reference/configuration.md`, `docs/reference/api.md`,
   `docs/guides/` (setting up an S3 store and switching to it), README.

### README example

A short section near the top: `logins/blocking.gsql` with two SETs (`is_blocked` from
a risk score, `is_suspicious` from an `RLIKE` on the lowercased message) and an
`UNSET password`, the JSON event sent with `return_keys`, the response, and a SELECT
with its result table showing the computed columns and no stored password.

## Open questions

Settled: 1 and 2 on their recommendations, with the alternatives removed; 3 on its
recommendation.

1. A statement that raises, or a batch over its heap or time limit. Recommended:
   fail closed, so the event is not stored and its result is an error naming the
   rule file and line. Failing open (store the event without that statement's
   effect) would store a password a failed `UNSET password WHERE ...` was meant to
   remove, and return no `is_blocked` to a client relying on it.
2. A table whose stored rules fail validation at load. Recommended: Guardian starts,
   events for that table fail with "rules for <table> are invalid (...); the event was
   not stored" until the rules are fixed through the MCP tools, and other tables run
   normally. The
   alternative, refusing startup, turns a hand edit or an upgrade that drops a
   function into a full outage that the MCP tools cannot fix, since they are down
   too. Running the table with no rules would silently skip its UNSETs.

3. Whole-set serialization across a partition. Recommended: accept the gap in
   "What this does not guarantee" above (a stalled writer or a very late request,
   both needing more than 60 s of delay), since a set it leaves invalid is caught
   at load and reported on the next write, and the default deployment is one
   machine. The alternative that closes it fully is one commit object that every
   write updates conditionally, which is a manifest.

## Switching an existing deployment to an S3 store

The [rules guide's switching procedure](../guides/rules.md#switching-an-existing-deployment-to-a-bucket)
is the operator runbook. The rollout decision was to verify conditional writes
from the deployment's network before switching stores, since the write lock depends
on those operations.

## Validation

1. Parser tests for each statement form, errors with positions, round trips through
   `to_source`, and contextual words still usable as column and table names.
2. Validation tests for every rejection above, a broken set repaired one file at a
   time, an unrelated table writable while another is invalid, identical duplicates deduplicated
   (including a self-reading `SET n = n + 1` in two files applying once),
   aggregates in WHERE, dependencies through WHERE.
3. Semantics tests: ordering, self-reads, UNSET after SET, case-insensitive reads
   and their tie-break, SET replacing an object, a list and a case variant, UNSET
   across case variants and nested paths, null for unknown fields, WHERE null,
   invalid rule outputs dropped, failing statements, a mixed batch where one event
   exceeds its limit (ordered outcomes, the rest stored), no event values in logs,
   Guardian's own writes untouched by rules.
4. Ingest tests over HTTP and MCP: computed fields in the response, unset fields
   absent from it, `return_keys` null for missing keys, nested results, stored rows
   queried back.
5. Store tests for the local folder, and for S3 against a fake S3 server in
   `libtest`: signatures checked against a known canonical request (prefix and
   continuation-token encoding, conditional headers), pagination, If-Match and
   If-None-Match, 412, a change between list and get, timeouts, oversized objects,
   and no secret in any log. No external services in tests.
6. Startup: unreachable store retried then refused, partial S3 settings refused, a
   table with an invalid stored set handled per open question 2.
7. Reload: an invalid change keeps the full prior set; a Rules restart keeps serving.
8. Compilation: repeated edits stay within the name pool; a reload that compiles one
   changed table and fails another leaves every published table on its old rules; a
   successful activation under concurrent ingest; a caller paused after reading the
   map while its table is updated or deleted still runs its old module.
9. Cluster tests with peer nodes (as the existing cluster tests do): a write reloads
   every node, concurrent writes serialize through the lock, an expired lease is
   taken over, a stale holder cannot release its successor's lock, an unknown save
   outcome leaves the lock held until expiry, a save refused with under 80 s left, local-folder writes refused with peers, polling catches a missed
   reload.
10. Full suite, `mix format`, warnings as errors.

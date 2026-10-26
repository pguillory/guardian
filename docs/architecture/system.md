# Guardian system architecture

This document describes how Guardian is built: its processes, the paths an event and a
query take through them, the storage engine, the interfaces, clustering, configuration,
deployment, and testing. Each part says why it is built that way and where it falls
short.

How this fits with the other docs:

1. What Guardian does, as a caller sees it, is the [product spec](../product/spec.md),
   which extends the [overview](../product/overview.md). This document assumes it and
   cites its sections instead of repeating behavior.
2. Trust boundaries, the API key, secrets, and logging exposure are the [security architecture](security.md). This document links
   to it rather than restating it.
3. Rules for editing a subsystem are in the `CLAUDE.md` file in each `lib/` directory.
   Those files are the working notes for agents changing that code; this document is
   the map that connects them.
4. Known limits are named where they arise and collected in section 12.

Where behavior was not verified, this document says so.

## 1. The shape of the system

Guardian is one Elixir release (OTP 28, Elixir 1.19 in the production image) with
three native components written in C. Each machine runs the whole system: HTTP and
MCP interfaces, the ingest path, a columnar storage engine over files on the
machine's own disk, and a query engine. Machines that can see each other form a
cluster in which every query and schema lookup runs on all of them.

```text
            producers, agents, scripts
                       |  HTTPS at the deployment's edge, then HTTP to GUARDIAN_PORT
                       v
  Bandit -> Guardian.Web.MainRouter -+- GET /health
                            +- /api/json -> Guardian.Web.JsonApi (auth, JSON, request log)
                            +- /mcp      -> Guardian.Web.MCP.Router (auth) -> Anubis -> Guardian.Web.MCP.Server
                                    |                     |
                           send_events                  query
                                    v                     v
                          Guardian.Web.Ingest -> Engine     Guardian.Query.Resolver -> Guardian.Query.Planner
                                    |                     |       \-> Guardian.Cluster.Metadata
                                    v                     v
                          Guardian.Storage.MutableSegments   Guardian.Query.run -> Guardian.Query.DistributedStream
                                    |                     |   workers on every node
                                    v                     v
                 Segment processes (NIF columns)       Guardian.Query.Evaluation
                                    ^                     | segment IDs only
                                    +---- Storage reads <-+ (segment_row_count,
                                    |                        get_column)
             FullSegments -> PersistedSegments -> {table}.{id}.seg on the volume
                                                        |
                                    LoadedSegments (mmap) <-+
```

The design follows from the product commitments (spec section 1):

1. Single user: there is no identity, namespace, or permission model anywhere in the
   code. Every storage and query operation is scoped by table only.
2. Schemaless: storage keeps one column per distinct flattened key, holding any mix of
   types, and the schema is whatever per-type counts the stored columns report. There
   is no catalog to keep in sync.
3. Predictable ingestion: the write path is a validation step, the table's rules (if
   any, compiled in memory), and an append to an in-memory segment. It calls no
   external service, and nothing on it waits for disk.
4. Read-only queries: the query language has no write statements, so the query engine
   only reads segments and builds temporary results.
5. Self-observing: Guardian's own metrics and logs go through the same ingest path as
   producer events, so they are ordinary tables.

## 2. Runtime and supervision

### 2.1 The supervision tree

`Guardian.Application` (the application module) starts these children in order, under a
`:one_for_one` supervisor:

```text
Guardian.Application (one_for_one)
├── Guardian.Rules.Server                     loads the rule store, publishes compiled rules, polls each minute
├── Guardian.Counters.Restarter               trapping lifecycle owner; backs off subtree recovery
│   └── Guardian.Counters.Supervisor (one_for_one)
│       ├── Guardian.Counters.Store           ephemeral node-local ETS counter storage
│       └── Guardian.Counters.Budget          failed-wait reservations and node-local cooldown
├── Storage (supervisor, rest_for_one)
│   ├── Guardian.Storage.Schema               per-table schema of loaded segments
│   ├── Guardian.Storage.LoadedSegments       mmap'd segment files; loads all at boot, rescans each minute
│   ├── Guardian.Storage.FullSegments         full in-memory segments waiting to persist
│   ├── Guardian.Storage.PersistedSegments    writes full segments to disk (shutdown budget 90 s)
│   ├── Guardian.Storage.MutableSegments      writable in-memory segments (shutdown budget 10 s)
│   └── Guardian.Storage.SegmentExpiration    deletes segments older than 15 days, every 10 minutes
├── SystemStats                      one system_stats row per second
├── Guardian.Web.QueryParseErrors             records query parse failures, asynchronously
├── Guardian.Web.QueryLog                     records every API query in `queries`, asynchronously
├── Guardian.Web.IngestIdempotency            bounded, node-local client-keyed ingest receipts
├── Web (supervisor, rest_for_one)
│   ├── Anubis.Server.Registry       MCP session registry
│   ├── Guardian.Web.MCP.Server               the Anubis MCP server process
│   └── Bandit.HTTP                  HTTP listener on GUARDIAN_PORT, default 8080 (shutdown 500 ms)
└── DNSCluster                       peer discovery; does nothing unless DNS_CLUSTER_QUERY is set
```

Why this order:

1. Guardian.Rules.Server starts first: its `init` loads and validates the whole rule set from
   the store (section 3.4), and a store that is unreachable or rate-limiting (after a
   minute of retries), or misconfigured, refuses startup. Starting before Storage
   makes a bad store fail in seconds instead of after every segment has loaded. It
   holds nothing the ingest path needs between calls: the compiled rules are in
   `:persistent_term`, so if it restarts, ingestion keeps the published rules and the
   new process reloads in the background instead of failing again.
2. Guardian.Counters.Restarter starts after Guardian.Rules.Server and owns a linked counter supervisor
   that starts Store with an empty public ETS table, then Budget with empty cooldown
   ETS and membership monitoring. It does no loading and is independent of rule
   compilation and event storage. Invalid Store options still refuse startup. Storage
   starts next, and `LoadedSegments.init/1` loads every segment file on the
   volume before returning. Supervisors start children one at a time, so the HTTP
   listener does not exist until all stored data is loaded. That is what lets
   `GET /health` double as a readiness check at boot (spec section 4.3), and it is why
   boot time grows with stored data. After boot, `GET /health` answers 503 unless
   `Guardian.Storage.ready?/0`: every Storage child is registered. It only looks up names, so it
   never blocks on a supervisor that is restarting children; because a GenServer
   registers its name before its `init`, it relies on SegmentExpiration starting last,
   after LoadedSegments has finished loading.
3. The writers of built-in tables (SystemStats, Guardian.Web.QueryParseErrors, Guardian.Web.QueryLog)
   start after Storage because they write to it.
4. Web starts after everything it calls.
5. Shutdown runs in reverse: discovery stops, then the HTTP listener (in-flight requests
   get at most 500 ms), so no new events arrive while Storage persists what it holds.

Inside Storage, `:rest_for_one` reflects dependencies: each manager calls the ones
before it (MutableSegments hands segments to FullSegments, PersistedSegments loads
through LoadedSegments, LoadedSegments registers schemas with Schema). If one crashes,
every later one restarts too. Each manager owns its segments' exits: all four
link their segments and trap exits, so a segment that crashes is unregistered and loses
only its own rows (a loaded one is reloaded from its file by the next rescan, up to a
minute later) instead of restarting the managers. Each manager's `terminate/2` runs on
shutdown and on any exit of the manager short of a kill (then the links kill its
segments): MutableSegments hands its segments to FullSegments, PersistedSegments
persists them and stops the cached ones, and FullSegments and LoadedSegments stop
whatever they still hold, so no registered segment outlives its manager.
PersistedSegments stops a cached segment when it releases it (section 4.2).
Deletion stops a segment's process too. A manager that itself crashes or stops is a
cascade: when FullSegments goes, MutableSegments has nowhere to hand its segments, so
its unpersisted rows and those of every writable segment are lost, and the restart
reloads what is on disk. Shutdown needs the managers' budgets in sequence: up to 10 s
for MutableSegments, 90 s for PersistedSegments, and the default 5 s each for
FullSegments and LoadedSegments (stopping about 1,100 loaded segments took 12 ms on the
development Mac), 110 s in all. A deployment must give the VM longer than that between
SIGTERM and a kill: on Fly, `fly.toml`'s 150-second `kill_timeout` covers it after
`bin/fly-start` has drained the tunnel connector (up to 10 s, and 20 s at worst before
it is killed; section 10.1), leaving at least 20 s for the processes that stop before
Guardian.Storage.

`Guardian.Application` uses the default restart intensity (3 restarts in 5 seconds). The release starts
the application as permanent, so if Storage or Web keeps crashing the VM exits, and the
deployment's supervisor restarts it (on Fly, `[[restart]] policy = "always"`).

Counter failures use a separate restart boundary. Guardian.Counters.Supervisor restarts each
child independently, with its own 3-in-5-second intensity. Guardian.Counters.Restarter traps
the linked subtree's exits, so even exhaustion (which exits with `:shutdown`) never
spends Guardian.Application's restart allowance. It logs an error with a fixed reason category and
retries after 15 seconds, doubling after each failed start or short-lived recovery
to a four-minute cap. One continuously healthy minute resets the delay. Failed
starts retry without crashing the owner, including when a prior owner's subtree
still holds names; it never adopts an old generation. A recovery logs at info.
On orderly shutdown Guardian.Application stops the stable owner, which synchronously stops its
subtree before exiting; no counter failure is logged and no retry survives.
The owner has an infinite shutdown budget for this cleanup, while its two leaf
children each retain the default five-second budget.

### 2.2 Native code

Two C components live in `src/` and are built by the Makefile through
`elixir_make`:

1. `column.c` (`priv/column.so`): the column NIF. It implements typed, packed columns
   and every per-column operation the query engine uses (arithmetic, comparison,
   filtering, type counts). See the [column reference](storage-columns.md).
2. `mmap.c` (`priv/mmap.so`): maps a segment file read-only and returns it as a
   binary. The descriptor is closed at once, and the mapping is removed when the last
   binary referring to it is garbage collected, so deleting a mapped file is safe.

Native code is used where it pays: columns because evaluation runs over every value of
a column. A NIF runs inside the VM, so a NIF bug can abort the whole node; the column
NIF validates every value before it can reach a C `assert`
(`lib/guardian/storage/column/CLAUDE.md`), but packed binaries it is handed are trusted. No
dependency brings native code of its own and no system library is linked, so the
build needs only a C toolchain and nothing in it is x86-only. Regular expressions
(`RLIKE`, `replace`) run on Erlang's built-in `:re` (section 5.6; `LIKE` is matched in
Elixir), and `count_distinct` uses `hypex`, a HyperLogLog written in Elixir.

## 3. Ingest path

```text
POST /api/json/send_events or MCP send_events
  -> Guardian.Web.Ingest.send_events/1           request validation, result shaping
       -> Guardian.Web.IngestIdempotency.run/5   optional keyed claim/receipt around Engine
  -> Guardian.Engine.ingest_events/2             table name check, then each event on its own
       -> Guardian.Storage.Flattening.flatten_event/1
       -> drop invalid values and over-long keys
       -> Guardian.Rules.run_with_metadata/2, if rules exist (3.4): a worker, one outcome per event
       -> drop invalid values the rules produced
       -> Guardian.Storage.append_flattened_result/2
            -> MutableSegments: pick the table's writable segment
            -> Segment.append (GenServer call into the segment process)
```

Internal writers go through `Guardian.Engine.log_event/2`, which stringifies keys and calls
`Guardian.Engine.ingest_event/2`, the raising single-event variant of the same path,
which never runs rules.
`Guardian.SystemStats`, `Guardian.Web.Logger` and `Guardian.Web.QueryParseErrors` call `Guardian.Engine.try_log_event/2`,
which returns a failure as `{:error, kind}`, so a write that fails (Storage restarting,
say) is skipped and logged by kind instead of crashing SystemStats, failing the
request, or crashing the recorder.

`Guardian.Failure` is the leaf helper for value-free diagnostic labels and stack
redaction, shared by Engine, Rules, Counters.Store and Web. It depends only on the
standard library; callers keep their own messages and catch/reraise policies.
Storage and Query name segment exit reasons with it directly too. Query
errors returned to callers are described separately by `Guardian.Query.Failure`.

Client idempotency keys are checked only at `Guardian.Web.Ingest`, shared by HTTP and MCP.
The coordinator returns plain outcomes (ran, duplicate with its failed-event count,
or a changed/pending/uncertain conflict); `Guardian.Web.Ingest` maps them to the
receipt body and HTTP 409/MCP tool-error messages. The supervised
`Guardian.Web.IngestIdempotency` coordinator starts before Web and never runs
ingestion itself. Its GenServer atomically claims `{table, key}` and monitors the
caller; that caller runs Engine and synchronously records a compact completion
before returning. Token and owner checks prevent stale completion/cancellation.
Caught exceptions, throws or exits explicitly record uncertainty before reraising;
monitoring alone cannot notice a failure caught by a reused HTTP/MCP process.

Only independent copies of bounded table/key strings, a SHA-256 digest of
deterministically encoded `{events, return_keys}`, tokens, monitors, status/count
and expiry are kept. There are at most 10,000 entries. Completed and uncertain
entries enter a monotonic expiry tree, cleared on claim and every second, and live
for ten seconds after completion. Pending entries do not expire. At capacity the
oldest completed entry is evicted first; with only pending entries left, the new
batch runs unprotected. Coordinator calls time out after 100 ms and catch exits;
unavailable claims fail open with a fixed info log, and completion failures do not
hide results. Timed-out claims receive an ordered token cancellation on the exact
coordinator pid, preventing a late claim from stranding a long-lived caller's slot.
No payload or full response is retained. No state is replicated or persisted:
retries on another node, cache eviction, expiry, fail-open operation and coordinator
restarts can duplicate batches. See spec section 5 for receipt/conflict semantics.
MCP's existing tool serialization can delay the check until the first call finishes.

### 3.1 Validation in Engine

1. Table names are checked once per request, before any event is touched. The rule
   (`[a-z_][a-z0-9_]*`, at most 64 bytes, not a tokenizer keyword or reserved name) is
   exactly what SQL can address as a bare identifier, so every stored table can be
   queried, and it keeps names safe inside filenames. The keyword list comes from
   `Guardian.AST.Tokenizer.keywords/0`, so the rule follows the tokenizer.
2. Each event is flattened (section 4.1) and every flattened value is checked with the
   column NIF's own validity test (`Guardian.Storage.Column.valid_value?/1`) and every key
   against the 250-byte limit. Invalid entries are dropped one by one; the rest of the
   event is stored. Using the NIF's own test means the rules cannot drift from what a
   column accepts.
3. The validated flat row is what gets stored. Engine never unflattens and
   reflattens it, because unflattening cannot represent every shape flattening accepts
   (lists mixing scalars and objects).
4. The event reported back to the caller is chosen carefully (`Guardian.Engine.reported_event`):
   the original when nothing was dropped, otherwise a rebuilt event, checked to hold
   every stored column, with a fallback that drops affected top-level fields. Spec
   section 5 item 4 describes what callers see.
5. Failures are classified by when they happen, which is what the three error
   messages (spec section 5 item 6) encode: before storage (not stored), an explicit
   storage refusal (not stored), or an exception or exit once the append has started
   (may have been stored, because a timed-out call can still complete). Exception
   details go to the server log.

Why validation lives in Engine and not Storage: Engine is the boundary where caller
input becomes a row, and the reporting rules need the original event. Storage
re-validates values as an assertion (`Guardian.Storage.Value.validate/1`), so a caller that
bypasses Engine fails loudly instead of corrupting a column.

### 3.2 Appending

`MutableSegments` keeps an ETS table of writable segments, keyed by segment ID with
the table name and segment PID. The append runs in the caller's process: it reads the
table's writable segments from ETS and calls one directly. Only creating a segment, or
handing one off, goes through the MutableSegments process.

1. A table normally has one writable segment. A new one is created only when the table
   has none (on first write, and after the previous one fills). The selection code
   picks between two random candidates by mailbox length when there are several, but
   nothing currently creates a second segment while one is open, so all writes to one
   table go through one segment process. Different tables append in parallel.
2. The segment appends a row atomically: every value is validated before any column
   changes.
3. A segment is full at 16,384 rows, when the packed size of its columns reaches its
   64 MiB budget, or one hour after its first row
   (`GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS`).
   The budget is soft: the row that crosses it is stored. The row that fills a segment
   triggers the handoff to FullSegments at once, so a quiet table does not wait for a
   next row.
4. An append that finds the segment full or dead retries in a new segment. An append
   that times out or crashes the segment is not retried, since it may have stored the
   row or may crash the next segment too.
5. A row is visible to queries as soon as the append returns, because queries read
   writable segments too (section 4.2).

Why one in-memory segment per table, appended through a process: the column NIF has no
locks and reallocates buffers as it grows, so a column must be touched by exactly one
process. Making that process the segment itself gives atomic rows and simple
visibility. The cost is that a table's ingest rate is bounded by one process, and an
append waits behind any reads queued on that segment (each read of a mutable column
packs a snapshot of it; `lib/guardian/storage/CLAUDE.md` covers the costs).

### 3.3 What the ingest path does not do

1. No durability wait: a successful response means the row is in memory, not on disk.
   Spec section 9 item 3 states the crash window.
2. No batching across events or enrichment. Each event is its own append call.
   Duplicate suppression is limited to the optional short-lived client-key
   receipts around Engine (section 3 above).
3. No bound on flattening cost beyond the 8 MB request body. Engine also flattens
   each event twice.
4. Request logging is synchronous: `Guardian.Web.Logger` writes the `web_requests` row through
   Engine before the request runs, so a stalled Storage delays every JSON API request.

### 3.4 Rules

Rules (spec section 5.1) are files of SET, UNSET, TRACK and LOOKUP statements, `<table>/<name>.gsql`,
in a rule store: a local folder or an S3-compatible bucket (`lib/guardian/rules/CLAUDE.md`;
the design and its reviews are `docs/changes/ingest-rules.md`).

1. Parsing and validation: `Guardian.AST.Parser.parse_rules/1` parses a file (statement words
   are matched by position, not reserved). `Guardian.Rules.RuleSet.validate/1` takes the whole
   set and returns each table's resolved `Guardian.Rules.Plan` (dependencies ordered, UNSETs last,
   identical duplicates merged) or its errors: parse errors, paths and limits,
   invalid scalar/aggregate use, a field defined two ways and cycles.
   `prepare/1` validates counter operators/scalar clauses/windows/targets,
   orders SET/TRACK/LOOKUP expression dependencies with a LOOKUP-before-TRACK
   barrier, and binds immutable definition identities through `Guardian.Rules.Resolution`.
   Invalid target tables propagate to dependent plans to a fixed point.
   It is pure. Typed per-kind steps (`Guardian.Rules.Step`), scalar/counter checks
   (`Guardian.Rules.Validation`) and dependency ordering
   (`Guardian.Rules.DependencyGraph`) are separate from rule-set orchestration.
   `Guardian.Rules.Activation.select/2` selects plans for Publisher activation:
   invalid components of old/new LOOKUP dependencies retain prior plans together,
   including deleted targets/dependents. Tables without a previous valid plan in
   such components are invalid.
   Valid unrelated components still activate. Server uses the same `prepare/1` on
   boot, reload and both sides of write admission. Local candidates have `resolved?: false`; only successful
   whole-set resolution marks them ready for compilation.
2. Compilation: `Guardian.Rules.Compiler` turns a plan into a module from a fixed template,
   calling `Guardian.Rules.Runtime.run/3` with dependency levels of typed steps as escaped literals
   (expressions run through the scalar evaluator, `Guardian.Query.Eval` on an event map). Names
   come from a pool of 1,024 (`Guardian.Rules.Compiled.M0`...), so atoms are bounded.
   Compiler independently refuses unresolved candidates and LOOKUPs without bound
   targets.
   A plan holds only its flat steps; Compiler derives the dependency levels from them
   once at compile time. Each generated module shares one escaped execution-level
   literal between ingestion and `plan/0`. For activation, `plan/0` reconstructs the
   exact resolved plan's flat metadata order using compile-time positions into those
   levels, including canonical source and AST constants, never executable rule text.
   Ingestion uses the prepared levels directly, without reconstruction.
3. Publication: `Guardian.Rules.Publisher` owns activation, publication and the
   generated-module pool, synchronously inside Server's scrubbed callbacks. Server
   keeps store reads, reload/poll, locked writes and admission; it holds Publisher's
   free/retired names and forwards reclamation messages. Publisher retains no plans,
   sources or diagnostics in its state. One `:persistent_term` map holds table to
   module, or `{:invalid, message}`. A reload compiles every changed table into free
   names first and publishes one new map only if all compiled, so a change is all or nothing on each
   node. A module the map stops using is retired, then after 30 s (rows run under a
   1 s limit) deleted and soft-purged; its name is reused only after the purge
   succeeds. On a restart the pool is rebuilt from what is loaded. Activation reads
   previous plans directly from the published modules, including after a Server
   restart while the stored copy is invalid or unreachable. Successful deletions
   still remove rules. Metadata is bounded by rule limits and the fixed module
   pool, reclaimed with the code; no separate per-reload history/cache is kept.
   Preparation errors and selected-table errors are combined for diagnostics,
   while write admission compares only the stored sets' preparation errors.
4. Running: `Guardian.Rules.Runner` runs a batch in a worker with the query heap limit (without
   the error_logger report), sending each row's result back; a row over 1 s, or a
   worker that dies, fails that row and a new worker continues. The worker reads the
   map per row. `Guardian.Rules.Runtime` resolves reads (exact key, else the first
   case-insensitive match in byte order), applies WHERE (true only), SET (remove the
   whole field in any case, then put) and UNSET (remove the path in any case and
   everything beneath). SET/UNSET exceptions fail the event; counter exceptions
   supply aggregate defaults and continue, including final UNSETs. At the first
   statement it indexes the row (`Guardian.Rules.RowIndex`): each lowercase spelling's present
   keys in order, and, at the first SET or UNSET that applies, a trie of keys by
   lowercase object path. A SET or UNSET then touches only the keys it removes and a
   read is a lookup, so an event's rules cost about its columns plus its statements,
   each times a log factor, rather than columns times statements.
   Engine captures private Unix/monotonic arrival coordinates before each event's
   validation; they are carried outside the row and never automatically stored.
   Runner shares one Client batch budget across worker replacements and starts
   each event's membership snapshot and counter phase on worker entry. Generated
   modules accept this context through `apply/2`; `apply/1` creates a fresh event/batch.
5. Loading: at boot, then on every write and every minute. The store is listed (a
   bucket under its prefix, or every file in a local folder through the generic
   `Guardian.ObjectStore.Local`); objects not ending in `.gsql` are ignored, a `.gsql`
   object at any other path than `<table>/<name>.gsql` is a path error, and
   objects whose ETag changed are fetched with `If-Match` on the listed ETag (a change
   in between restarts the read). A table invalid at boot is published as invalid; a
   running node keeps a table's previous good module if its stored copy turns
   invalid.
6. Writes (`Guardian.Rules.Server`): take the lock, an object in the store at
   `_write.lock` (the object-store client's generic key lock, `Guardian.ObjectStore.Lock`:
   `If-None-Match: *` create, 120 s lease judged by the store's own clock, takeover of
   an expired or released lock with `If-Match`, ownership-safe release), read the set
   from the store, refuse the change if it adds an error, check 80 s of lease remain,
   save the one file conditionally (20 s deadline), release, publish locally, and ask
   every connected node to reload (10 s). An unknown save outcome leaves the lock to
   expire. Server owns the rule lock key, lease and save margin. Store capabilities
   come from the generic `Guardian.ObjectStore.shared?/1` callback (optional, default
   true): S3 is shared, Local is not. With a local folder and peers connected,
   writes are refused. A local folder writes each rule or lock file through
   `Guardian.AtomicFile.write/2`, as segments are written (section 4.3): a crash never
   leaves a torn file, but a power
   loss can roll a recent write back to the previous version, or to no file for a
   new key (no directory fsync), and a crash mid-write can leave an ignored
   `{key}.{n}.tmp` file.
7. The S3 client is the generic `Guardian.ObjectStore.S3` (`lib/guardian/object_store/`):
   Req with SigV4 (`service: :s3`, region `auto` for R2), path-style
   URLs, `:xmerl` for ListObjectsV2, 5 s connect and 15 s receive timeouts, no
   retries. Credentials stay in a closure; requests carry an MFA for signing; every
   store call returns a reason naming only a kind (security.md).

Why a lock object and not `:global`: `:global` gives each side of a partition its own
lock. Why no manifest: the design keeps the store as plain files, so a set
validated on a write is serialized by the lease but not fenced: a writer stalled past
its lease, or a request applied long after it was abandoned, can still leave an
invalid set, which loading then handles per table (spec section 12).

### 3.5 Counters

`Guardian.Counters.Store` is the node-local foundation for TRACK/LOOKUP
(`docs/changes/ingest-rules.md`). Public whole-set validation and Compiler admit
resolved counter plans; generated modules call `Guardian.Rules.CounterRuntime` through
the typed-step dispatcher. It keeps LOOKUP-before-TRACK ordering,
uses the mutation's returned state for current-event inclusion, defaults the
whole result on any failed operation, and leaves SET/UNSET failures fail closed.
Buckets retain the complete oldest intersecting interval (overcount bias).
TTL durations decrease toward bucket_end+window, anchored to private monotonic
arrival coordinates; network/queue transit can delay physical expiry. Only
definite CAS conflicts retry, with three total attempts within Budget limits.
It adds no external service. SET/UNSET-only events capture private arrival/routing
metadata but make no counter-store calls. Counter identities include table, output
name and the SHA-256 of canonical TRACK source; LOOKUP plans bind target identities.
Edits start fresh, while moves/comments/whitespace retain state. Queries only read
stored historical output fields. No later rule/storage failure rolls back updates.

Counters and queries share one aggregate registry, `Guardian.Aggregation`, with one
configuration per aggregate: every registered name/arity is a TRACK operator, and
TRACK validation checks the same registry the parser uses. Step construction builds
each TRACK's immutable CounterDefinition, the single owner of its identity,
operator, window/bucket sizes and grouping arity. Validation checks its operator
and window before plan construction; LOOKUPs bind the same definitions, and Runtime
reuses them rather than constructing metadata per event. Execution selects the aggregation
with `Guardian.Aggregation.fetch!(name)` from the definition's operator and passes
it through empty/start/merge/finish and key machines. CounterDefinition owns the
struct-shaped input used to hash LOOKUP targets; Resolution encodes it
deterministically. The name/arity also controls native-count dispatch. This metadata
representation preserves counter identities and dependent plan hashes.
Every aggregate has an empty mergeable state, an exact identity of its merge; a
query's no-rows default is that state finished, so a missing counter and an empty
query give the same result (sum's is null). Arbitrary and the top-N family use the
non-storable atom `:empty`, distinct from a real null. HLL is precision 8/Bitstring
(256 bytes) everywhere. Count finishes raw: the int64 limit applies where values
are stored (Engine's rule-output validation, query column construction). Average
skips states with no values, retaining signed-zero bits. All arithmetic, overflow
and ordering logic lives in the shared modules. The registry's `finish` boundary
nulls list results that storage cannot hold, leaving valid lists and all scalar
results unchanged. A merge that raises (top-N states with different n) fails that
counter open: Machine turns it into a bucket error, and Runtime's counter guard
catches it across buckets. These states are plain terms safe to copy through ETS
and distribution; no resources or ownership transfer are involved. HLL registers
have fixed size; arbitrary, min/max and the `_by` forms retain one input of
variable byte size, the `_n` forms up to n of them, and count/avg exact integer
sizes grow logarithmically with accumulated count/sum. State size is not an
absolute byte constant and has no cap of its own; Store's payload checks and memory
target still apply.

One GenServer owns one public ETS set, with {encoded_key, value, expires_at,
version} rows. Ordinary get/gets, create-if-missing, CAS and native increment run
directly in callers and remote handlers. Deterministic ETF binary keys make CAS
select_replace and conditional expired deletion keyed operations, including for
maps and match-spec atoms. This encoding is ephemeral and local to Store, separate
from Transport's phash2 owner routing. A reserved atom row holds the immutable
descriptor (clock, budget, table generation and baseline). Named stores use ETS
name/descriptor lookup; unnamed PID stores retrieve the table reference from the
owner's process dictionary. A captured table reference cannot address a replacement
generation after restart. Suspending the named housekeeper does not stall callers.

Incr uses one update_counter list to change the integer value and assign a fresh
positive unique version through a threshold/reset operation. CAS tokens contain the
table reference and version, preventing reuse across updates, eviction/recreation
and restart. CAS keeps the existing expiry; creation sets it once from the owner's
positive millisecond TTL. Reads treat expiry<=now as missing. When a physically
present expired row is reused, conditional deletion plus one retry permits creation
without deleting a concurrent fresh row. Ordinary bucket identities advance and
do not revisit expired keys. A second expired increment returns a definite :expired
error, never an unbounded retry or replay of a successful live increment.

Client accepts only batched operations; Transport's remote endpoint accepts only
owner pipelines.
Store retains the local atomic primitives; Store.batch executes
up to 4,000 operations in order and checks the original deadline before each.
Deadlines are checked after clock/key preparation and before mutations/retries.
The 50 ms default remains; Transport bounds waits on its helpers. Errors and status
disclose no keys/values. Restart clears only counters, not Storage or Rules.Server.

Housekeeping bulk-deletes expired rows about every second, then folds resident
rows to measure ETS bytes above fixed empty/descriptor overhead plus serialized
encoded keys/values and retained backing allocations in nested value binaries,
bitstrings and function environments. Encoded keys detach original key slices.
Shared backing and inline data can be counted more than once. Diagnostic stats
perform the same fold, so their results are approximate under concurrent changes.
GUARDIAN_COUNTER_MEMORY_MB still sets positive MiB, default 64; explicit
empty/invalid values refuse startup. This is an asynchronous memory target:
concurrent writes can exceed it between housekeeping turns and during reclamation.
Individual payloads too large to fit are refused before writing.

Over budget, housekeeping samples up to 256 expiries, bulk-deletes buckets through
the sample's median expiry and repeats up to four passes per tick. Tied expiries
can evict more than half, including every live bucket. If still over budget, the
next tagged tick runs immediately; otherwise it waits one second. Stale tags do
nothing and manual sweeps do not add a timer chain. All reclamation stays outside
writes; a completed write can subsequently be evicted without changing its reply.
The budget excludes temporary copies, mailboxes and the rest of the VM. See
[counter-store.md](../changes/counter-store.md) for design and validation.

`Guardian.Counters.Client` is the facade used by Rules and the key-machine runner.
It delegates batch dispatch to internal `Guardian.Counters.Transport`, which owns
routing, owner pipelines and bounded guard/worker dispatch. Internal
`Guardian.Counters.Budget`, independently supervised after Store inside the counter
subtree, enforces event deadlines and owns failed-wait reservations and cooldown ETS
lifecycle; its admission and settlement use atomics/ETS directly, never its mailbox. Client takes
one connected-member snapshot per event, without Storage readiness RPCs. Its typed
`Guardian.Counters.Context` captures the deadline before membership and carries the
shared batch handle, operation allowance, cooldown table and store server. Rules.Event
nests it under counters, separate from private Unix/monotonic arrival coordinates.
Transport calls Store directly in production; test builds select a libtest adapter
at compile time for transport probes. No backend tuple handling enters the production
path. Transport chooses the highest rendezvous score
`{:erlang.phash2({{identity, group}, member_name}, 4_294_967_296), member_name}`,
where member_name is the node's string name and breaks hash ties
(`Guardian.Rendezvous`, shared with GROUP BY routing). phash2 accepts
any term and distinguishes integers from floats. Signed zeros share an owner but
remain distinct stored counters through Store's ETF keys. All buckets share one owner.
Each dependency level expands its counter statements into bucket key machines;
`Guardian.Counters.Machine.run_nested/3` runs them together in batched rounds and restores
the per-counter result lists. `Guardian.Counters.KeyMachines` supplies read, native incr,
and gets/merge/CAS callbacks. Buckets combine oldest to newest, resolving once;
any failed bucket defaults its whole statement. LOOKUP ancestors and LOOKUP levels
drain before any TRACK level. Scalar work finishes before a level dispatches, and
UNSETs remain last.

Each round groups operations by owner into one Store.batch pipeline per owner;
owners run concurrently within the reservation budget. Pending owners wait for
any completed pipeline's refund instead of defaulting while allowances are merely
reserved. With a small remaining allowance, a slow owner can delay pending owners
until it completes or times out. A pipeline with any failed operation except CAS
conflict charges one
owner wait, using its completion timestamp; healthy pipelines refund fully.
Anchored bucket expiries become decreasing TTLs when each pipeline dispatches.
Remote operations call Store directly
on that owner, preserving terms and opaque CAS tokens, never re-routing or failing
over to another owner. The RPC entry point is
`Guardian.Counters.Transport.remote_operation/3`, with the same batch terms and
remaining-duration arguments. The former Cluster module is removed; multi-node
rolling deploys across this split are unsupported. Mixed-version calls fail as
unavailable, mark owner cooldown and use fail-open defaults until every node runs
the same build. Booting peers without the endpoint also fail open.

Runner calls `new_batch/0` outside workers and `new_event/2` on worker event entry.
One event has a 100 ms wall-clock counter phase; operations use at most 50 ms and
skip without dispatch below 10 ms remaining. A shared atomics handle reserves from
250 ms of failed-call wait per batch, survives rule-worker replacement, and refunds
healthy calls fully (including misses/CAS conflicts). Failed calls refund unused
allowance; a killed caller conservatively spends its outstanding reservation.
This event wall-clock deadline is deliberately stricter than summing call time.
Healthy calls can still accumulate latency across events; the batch allowance
bounds failed waits, not the whole batch's duration.

A local guard monitors the caller and links a worker that may block in distribution
flow control. Both local and remote calls use the same bounded path. Deadline or
caller death kills the worker; caller cleanup revokes the reply alias, consumes the
guard's DOWN and flushes already delivered replies. Local requests retain the
original deadline; remote endpoints translate remaining milliseconds to their own
monotonic clock. Transit before endpoint receipt and already dispatched mutations
can outlive the wait; uncertain increments are never replayed.

An independent public ETS table holds one-second cooldowns for suspect owners,
including the local Store. Unavailability marks immediately; timeouts mark only
with at least 25 ms allowance. Budget skips and definite Store errors never mark.
Reads/cooldown updates never wait for the Budget GenServer. It monitors membership
and prunes expired/departed entries, at least once per second; no user key goes in
this map. Restarting Budget clears cooldowns; while absent, operations fail fast.
Membership changes, divergent membership views, restarts, eviction and uncertain
late writes can lose or split counts. Availability takes precedence over precision;
there is no replication, migration or partition recovery protocol.

`system_stats.counters_available` reports whether the counter supervisor, Store and
Budget are registered. This samples presence without waiting for any process; it
is not a responsiveness probe. It becomes false during subtree downtime or a child
restart and true after recovery. `/health` continues to depend only on Guardian.Storage.

## 4. Storage engine

`lib/guardian/storage/CLAUDE.md` is the authoritative description of the segment lifecycle
rules. This section explains the structure and the reasons.

`Guardian.Storage` is the subsystem's only public module (besides the data modules `Column`,
`Column.Metadata`, `Value` and `Flattening`). Code outside `lib/guardian/storage` names segments
by ID and never holds a segment's PID, so Storage can change how segments are held
without touching query code.

### 4.1 Data model: tables, segments, columns

1. A table is a set of segments with the same table name. It has no other existence:
   it appears with its first segment and disappears with its last.
2. A segment is a batch of up to 16,384 rows held as one column per flattened key.
   Each segment is an Erlang process (`Guardian.Storage.Segment`), identified by a segment ID:
   32 hex characters encoding the creation time in nanoseconds plus 8 random bytes
   (`Guardian.SegmentID`). IDs sort by creation time and are unique across machines, which is
   why the same ID can be listed by two lifecycle stages and simply deduplicated.
3. A column holds any mix of null, boolean, 64-bit integer, float, string, and list
   values (lists of scalars, or of lists of scalars). While a segment is writable a
   column is a mutable NIF resource; once frozen it is a packed binary. Packed columns
   are ordinary binaries, so they can be shared between processes and sent between
   nodes without conversion.
4. Each column reports its metadata as a list of 8-tuples of counts (total, null,
   false, true, int, float, string, list), one per layer: the first describes the
   column's values, and a column holding lists has a further tuple for the values
   inside those lists. These counts are the whole type system: schemas are maps from
   column name to such lists, and merging schemas adds them element by element. The
   virtual `schema` table reports the first layer.
5. Nested objects become dotted column names, and lists of objects add one dot per list
   level (`users..name`), spec section 6.3. Flattening at ingest means the query engine
   and the column NIF never see maps.

Why columnar: queries are mostly scans with filters and aggregates over a few columns
of many rows. Evaluating an expression over a whole column at once in C is far cheaper
than interpreting it per row, and a scan reads only the columns it names. Why so many
small segments rather than one file per table: segments are the unit of persistence,
of parallelism, and of retention, and a fixed row cap keeps every operation on one
segment bounded.

### 4.2 Segment lifecycle

A segment moves through four managers, each an ETS registry owned by a GenServer:

1. MutableSegments: writable segments (section 3.2).
2. FullSegments: frozen segments waiting to be written. The handoff registers the
   segment here before removing it from MutableSegments.
3. PersistedSegments: every second (and on each handoff) it packs each full segment's
   columns inside the segment process, writes the file, registers the segment as
   persisted, and removes it from FullSegments. The in-memory segment stays registered
   for 10 minutes, so queries keep using it while the file is picked up.
4. LoadedSegments: segments backed by a memory-mapped file. After the 10 minutes,
   PersistedSegments asks LoadedSegments to load the file if it has not already (it
   also finds new files on its own each minute), then drops its own entry and stops
   the in-memory process. Lookups check LoadedSegments first, so once the file is
   loaded no new read reaches the in-memory process; a read that resolved it just
   before the file was loaded is retried once on the loaded copy, which holds the
   same rows. If the file cannot be loaded, the in-memory process keeps serving and
   the check is retried.

Ordering is the correctness argument for visibility. Every handoff registers the
destination before removing the source, and `Guardian.Storage.segment_ids/1` reads the registries
in lifecycle order (Mutable, Full, Persisted, Loaded), so a segment moving during a scan
is seen at least once; duplicates are removed by ID. `Guardian.Storage.get_segment/1` checks
Loaded again at the end, because a segment can leave the persisted cache after the first
Loaded lookup.

Known limits of the lifecycle:

1. Deletion is not serialized with persistence. A segment deleted while the persister
   writes it, or after its file was written but before LoadedSegments registered it,
   leaves a file that the next rescan loads again.
2. A segment that dies between LoadedSegments starting it and Guardian.Storage.Schema
   registering it (both call the segment) still crashes those processes: their reads
   return `segment_unavailable` at once, and they match only success. Their reads
   carry a 5 s timeout, so a hung segment crashes them rather than blocking them.

### 4.3 Persistence and the file format

A persisted segment is one file, `{data_dir}/segments/{table}.{segment_id}.seg`:

```text
primary header   9 x 64-bit big-endian integers: row count, then the byte size of
                 each of the 8 secondary-header columns
secondary header 8 packed columns, one entry per stored column:
                 keys, null/false/true/int/float/string counts, byte sizes
column data      each stored column's packed binary, in key order
```

`Guardian.Storage.SegmentFile` encodes and decodes this layout and owns the filename rules;
`test/guardian/storage/segment_file_golden_test.exs` pins it byte for byte.

`Guardian.Storage.BlobStore.write/2` writes the file through the shared leaf
`Guardian.AtomicFile.write/2` (also used by the local rule folder, section 3.4):
under a unique temporary name (`{final}.{n}.tmp`), fsynced, then renamed into place,
so a reader never sees a partly written file under the final name, after a VM crash
or a host crash.

Why this format: it is the packed columns themselves plus enough header to find them,
so loading is a map and a header parse, with no decoding of column data.

Limits:

1. The file is fsynced before the rename, but the directory is not (Erlang cannot
   fsync a directory, and a NIF for it was judged not worth its cost). A host
   crash or power loss soon after a write can lose the rename, leaving the segment
   missing rather than torn.
2. No magic number, version, or checksum. A file is trusted to be what its name says.
3. An unreadable file (truncated, empty, with a bad header, or not mappable) is
   skipped, not loaded: the rest of the data stays available (section 4.4). Corrupt
   column data that does parse aborts the VM inside the column NIF. A loaded
   segment that raises while answering a query is unregistered, and the next rescan
   loads its file again (section 2.1).
4. A segment that cannot be written (full disk, rejected filename) is logged once,
   stays in FullSegments and queryable, and is retried every pass; its memory is held
   until it persists or the machine stops.
5. A store failure is handled per segment (item 4), at shutdown too, since shutdown
   runs the same persist loop. So is a segment that dies or stops answering while it
   packs: the persister moves on, and the segment is unregistered when its exit
   arrives, or retried next pass if it is alive. A pack step that raises (an
   unexpected reply such as `{:error, :not_frozen}`) still crashes the persister, and
   at shutdown aborts persistence of the remaining full segments.
6. Temporary files left by a crash mid-write are never cleaned up; their names do not
   parse as segments, so they are ignored without a warning.

Changing the format or filename scheme needs an explicit migration plan
(`lib/guardian/storage/CLAUDE.md`). Files in the older `{user_id}.{table}.{segment_id}.seg`
format are ignored with one startup warning and never deleted.

### 4.4 Loading, mmap, and rescans

At boot, LoadedSegments lists the segment directory and starts one segment process per
file, each holding the file mapped with `Guardian.Storage.Mmap`. Columns are sub-binaries of
the mapping, so they occupy page cache, not VM heap, and the kernel pages them in as
queries touch them. Every 60 seconds it rescans the directory: new files are loaded,
and segments whose files disappeared are stopped. That rescan is what makes restoring
or removing files take effect without a restart (spec section 9 item 6).

A file that cannot be loaded (section 4.3, limit 3) is skipped. The segment process
starts unlinked and validates the file in its `init` (header, column bounds, and each
column's metadata), stopping with a reason that names only the failure's kind, so
neither LoadedSegments nor a crash report sees the file's bytes; a segment that loaded
links itself to LoadedSegments before its `init` returns. LoadedSegments logs one
error line (filename, size, reason) and leaves the file in place. A file that could
not be opened or mapped (permissions, descriptor limits) is retried on every rescan.
For a content failure it remembers the file's size, mtime, and inode, taken before
the attempt, and rescans and cache evictions do not retry the file until one of those
changes, so an operator who
restores a good copy (written under another name, then renamed into place, never
copied over the file) sees it loaded on the next rescan. A skipped file that disappears
is forgotten, and SegmentExpiration deletes skipped files on the same 15-day schedule
as loaded ones. `Guardian.Storage.delete_table/1` (no interface calls it) does not see skipped
files. If PersistedSegments finds the file it just wrote unreadable when its cache
expires, it rewrites the file once from the in-memory segment and, if that fails too,
keeps serving the segment from memory and retries every 10 minutes.

Why mmap: a machine's stored data can be larger than its memory (the repository's
`fly.toml` pairs a 10 GB volume with a 1 GB machine). Mapping lets every segment be registered and queryable
without reading it, and lets the kernel evict cold columns.

Cost: loading still starts a process per file and computes its schema, so boot time
grows with the number of segments; the Fly health check allows 10 minutes for it.

### 4.5 Schema inference

`Guardian.Storage.Schema` keeps, per table, the summed column counts, row count, and segment
count of all loaded segments. It monitors each loaded segment and subtracts its counts
when the process stops, which is why unloading a segment must stop its process, and a
table is forgotten with its last loaded segment. `Guardian.Storage.schema/1` adds the counts of
the table's writable segments on top (skipping one deleted or stopped while it reads;
one that does not answer within 5 s fails the lookup rather than dropping its
columns), and `Guardian.Storage.table_names/0` likewise lists tables
with loaded or writable segments. There is no persistent catalog. The model has a gap: a
segment that is full or recently persisted but not yet loaded (normally under a minute,
longer if its write fails) is read by SELECT but left out of the schema, so `SHOW
TABLES`, `DESC`, the `schema` table, and `SELECT *` can briefly miss its columns or, for
a table with no other segments, the table itself. Across machines, `Guardian.Cluster.Metadata`
adds every node's schemas together (section 7).

### 4.6 Retention

`Guardian.Storage.SegmentExpiration` runs at boot and every 10 minutes. It deletes every loaded
segment whose ID timestamp is more than 15 days old: the file is removed and the
segment process stopped. Age comes from the segment ID, that is from when the segment
was created, not from event timestamps. Retention is global and the 15 days is a
constant in code. There is no other deletion path through the product; operators can
call `Guardian.Storage.delete_table/1` and `Guardian.Storage.delete_segment/1` from the remote console.

### 4.7 Memory

Memory on a machine is roughly:

1. Writable segments: one per active table, up to the 64 MiB packed budget each, and
   mutable columns can hold about twice their packed size.
2. Full and recently persisted segments: their packed columns, until persisted and for
   10 minutes after (`:guardian, :persisted_segment_cache_ms`).
3. Loaded segments: page cache for the mapped files, which the kernel can evict, plus
   a small process per file.
4. Queries: rows in flight, GROUP BY state, sort buffers, and results, bounded only
   partly (section 5.7).
5. Counter storage: resident ephemeral rows with an asynchronously enforced budget
   (temporary overshoot possible), plus mailbox/temporary copies outside it (section 3.5).

Nothing bounds the number of active tables or keys per segment, so memory is the effective limit. An
out-of-memory kill skips the graceful shutdown and loses every unpersisted event on
the machine.

## 5. Query engine

```text
SQL text
  -> Guardian.AST.Parser (tokenizer, recursive descent)          lib/guardian/ast
  -> Guardian.Query.Resolver (SHOW/DESC, LET, columns, SELECT *)  uses Guardian.Cluster.Metadata
  -> Guardian.Query.Planner (list of plan steps)
  -> Guardian.Query.run: Guardian.Query.DistributedStream over every node, Guardian.Query.Evaluation per segment
  -> rows (lists of values), labeled by Guardian.Query.Resolver.labels/1
```

### 5.1 Parsing

`Guardian.AST.Tokenizer` and `Guardian.AST.Parser` are hand-written: a tokenizer and a recursive-descent
parser producing structs, one module per node type under `lib/guardian/ast/node/`. Each node
module implements the `Guardian.AST.Node` behaviour: it can print itself back as source
(`to_source/1`) and be traversed (`traverse/4`, through `Guardian.AST.Node.traverse_fields/5`
for nodes with children); column
labels are the source text of each select expression, which is why round-trip printing
matters (a label from `INTERVAL n WEEK` that cannot be re-parsed is one gap). Function and aggregate names are
checked against their registries during parsing, so an unknown function is a parse
error. Errors carry "Expected X, got Y" messages. See `lib/guardian/ast/CLAUDE.md`.

Why hand-written: the language is small, error messages matter to agents that read
them, and the same structs serve parsing, printing, and evaluation.

### 5.2 Resolution

`Guardian.Query.Resolver.resolve/1` turns source text into executable SELECT statements:

1. `SHOW TABLES` and `DESC t` become SELECTs on the virtual `schema` table.
2. `LET name = expr;` substitutions are applied to the statements after them.
3. Column names are matched to stored names ignoring case, using the merged schema of
   each table the statement reads; two stored names that differ only by case raise
   `Guardian.Query.AmbiguousColumnError`. Evaluation itself is case-sensitive, so anything
   that skips the Resolver is too.
4. `SELECT *` expands to the table's columns across all machines.

It returns each statement paired with its column labels, taken from the statement
before LET substitution (`Guardian.Query.Resolver.labels/1`). Resolution needs schemas, so it
is the one step before execution that talks to other machines (section 7).

### 5.3 Planning

`Guardian.Query.Planner.query_plan/1` rewrites a SELECT into an ordered list of steps by peeling
clauses off from the outside in (`Guardian.Query.Executor` runs them):

1. `{:from, table}`: list segments on every node (or a one-row column snapshot for
   SELECT without FROM, or the virtual schema table as one column snapshot).
2. `{:select_where, exprs, where}` or `{:select, exprs}` and `{:where, expr}`:
   evaluate expressions per segment, filtering by the WHERE column.
3. `{:group_by, keys, aggregates}`: aggregate. A select list that mixes aggregates
   with other expressions, and HAVING, are planned as a first aggregation, then
   `{:reassemble_segments, ...}` packing its output into column snapshots, then a
   second SELECT over those. An aggregate without GROUP BY groups by a constant and
   adds a `{:default, row}` step, so an empty table still returns one row.
4. `{:order_by, directions}`, `{:limit, n}`, or the combined
   `{:order_by_limit, directions, n}`. ORDER BY's expressions are selected ahead of
   the statement's own, so these steps carry only each key's direction (`:asc` or
   `:desc`) and the integer limit.

There is no cost model and no index: every plan scans every segment of the table.
`Guardian.Query.Evaluation.pre_eval/1` can fold constant subexpressions, but the query path does
not call it; constants are evaluated per segment as constant columns, which is cheap.

### 5.4 Distributed execution

`Guardian.Query.run/1` executes the plan (through `Guardian.Query.Executor`) with `Guardian.Query.DistributedStream`
(`lib/guardian/query/distributed_stream.ex`, vendored from the `distributed_stream` 0.1.4 Hex
package). Its moduledoc is the contract (API, failure
model, exit reasons) and `lib/guardian/query/distributed_stream/CLAUDE.md` holds the protocol's
editing rules.
DistributedStream builds a pipeline of stages; each stage is a set of worker processes
spread over nodes by a fan-out function, and a router process per stage on the
coordinating node spawns workers on demand and tracks when they finish. Workers send
rows downstream in chunks: a chunk is sent once it reaches about 1,000 serialized bytes
(a single row can exceed that), with a ready-for-input handshake, so a slow consumer
holds back producers.

How Guardian's plan maps onto stages:

1. FROM fans out one worker per connected node. That worker lists the node's own
   segments for the table and, in the same stage, evaluates the SELECT and WHERE
   expressions against each segment in turn. Data never leaves the node it is stored
   on; only result rows travel. Each node scans with a single worker per query.
2. GROUP BY repartitions: each row is sent to one of the cluster's aggregation
   partitions (up to two per node), chosen by rendezvous hashing on the group key
   (`Guardian.Rendezvous`, highest 32-bit phash2 score, ties broken by partition), so all
   rows of one group meet in one process. Each partition
   aggregates into an ETS table with the aggregation's `start`, `merge`, and `finish`
   functions (`lib/guardian/aggregation/CLAUDE.md`; merge must be associative because partial
   results combine across segments and nodes).
3. ORDER BY ... LIMIT n sorts and truncates to n on each worker, then merges on the
   coordinator. ORDER BY without LIMIT collects everything on the coordinator and sorts
   it in memory. LIMIT without ORDER BY stops the stream after n rows.
4. Results are gathered on the coordinator, counted against the result caps, and
   returned as a list.

Process structure and failure handling:

1. `Guardian.Query.run/1` runs the query in its own process, which traps exits and is the
   pipeline's consumer. It links one router per stage and a final router (which
   names the consumer as the last stage's receiver). Routers trap exits and start
   their workers with `Node.spawn_link/2`, so every worker's exit reason reaches its
   router; the first router also starts the initial worker (the process that reads
   the first stage's input). A linked watcher monitors the caller and the query
   process: the caller's death ends the query, and the watcher exits with the query
   process.
2. Any abnormal exit (a worker that crashes, a lost node's `:noconnection`) makes its
   router exit with that reason; the consumer then stops the rest of the pipeline and
   the query raises a `Guardian.Query.Error`. Exit signals interrupt even a worker blocked in a
   call, so nothing is left running. A worker reports to its router that it finished
   before exiting, so one that ends normally without finishing fails the query too.
3. Edges carry their own checks, because a connection between two worker nodes can
   drop and reconnect without breaking any link (all links run through the
   coordinator). A sender asks the stage's router for its receiver and blocks on the
   reply, so the router records every edge; once the upstream stage is done, the
   router tells each worker exactly which senders to wait for. Each sender ends each
   edge with a marker carrying its chunk count, and both ends monitor each other (the
   first chunk on an edge is acknowledged before the sender goes on, so the receiver
   is already monitoring it if it dies). A missing chunk, a missing marker, or a peer
   that went down while still needed fails the query. Every protocol message carries
   its pipeline's reference, so pipelines that share a process (nested pipelines) never
   mix their messages.
4. No stage wait, and no segment read from a query (5.7), has a timeout: a slow stage
   or segment is waited for, up to the query time limit. An early LIMIT stops the
   pipeline with `{:shutdown, :halted}` exit signals before the rows are returned.
   Stages must read all their input: a worker whose input stream did not reach its
   end fails the query with `worker_finished_early`.
5. Expression evaluation in workers runs under `Guardian.Query.WorkerErrors.guard/2`, which
   reports the first exception to a collector, skips the worker's remaining work, and
   raises it once the stream ends. Workers then never crash on expression errors, so
   no crash report carries row values into the log. GROUP BY's aggregate steps (start,
   merge, finish) are guarded per element the same way.
   HAVING's reassembly is not guarded; a crash there fails the query and is logged.
6. A node that times out or fails DistributedStream's partition lookup
   (`partitions/1`, a 5-second multicall) gets no GROUP BY partitions; its rows hash
   to the others' partitions, so nothing is lost.
7. The query process and every worker, including the initial worker, put this node's
   heap limit on themselves as they start (`Guardian.Query.Limits.limit_heap/0`, section 5.7);
   routers do not. A process the limit kills exits `:killed`, which fails the query
   like any other abnormal exit, with a message that hedges about the cause.

Why DistributedStream: it gives a lazy, backpressured, multi-node pipeline with little
code, and it keeps computation next to the data. The published `distributed_stream`
package's failure model (unlinked workers, timeouts read as completion) silently
truncated results; Guardian's vendored copy replaces it and has diverged from it.

### 5.5 Evaluation

`Guardian.Query.Evaluation` evaluates an AST expression against a context: a segment snapshot,
an event map, or nothing (constants). For a segment it produces a whole column (or a
constant with a row count, `Guardian.Query.ColumnOrConstant`), so `a + b` is one NIF call over
two columns. A snapshot names a segment by ID with a row count fixed when the query
listed it; the worker looks the segment up locally, so rows appended after that are not
seen. Query temporaries (the one row of a SELECT without FROM, the `schema` table, and
reassembled GROUP BY output) are snapshots that hold their columns instead: a map from
key to packed binary, with no process behind it, freed when the last stage drops it.

1. Operators are AST node modules that carry their own evaluation
   (`lib/guardian/ast/node/operators/`).
2. Scalar functions are modules registered by name and arity in `Guardian.Query.Function`; each
   has a scalar `eval/N`, which `Guardian.AST.Node.FunctionCall` maps over the argument columns,
   and only the few that need more (short circuits, literal compilation, NIF paths)
   define their own columnar `eval2/2`. Most return null on wrong-type input instead
   of failing (`lib/guardian/query/function/CLAUDE.md`).
3. Aggregates are registered in `Guardian.Aggregation` and planned, not evaluated as functions.
4. Regular expressions compile once per evaluation (per segment), not per row, when
   the pattern is a literal (section 5.6).
5. Column metadata enables short cuts: an all-true or all-false WHERE column skips
   filtering, and `if` and `coalesce` skip branches that cannot be taken.

`Guardian.Query.NativeDispatch.evaluate/3,4` owns scalar/native selection for
arithmetic, boolean operations, `to_boolean` and `to_string`. Callers identify the
operation and supply its scalar callback. Constants use scalar evaluation; native
arithmetic over columns falls back to scalar evaluation for timestamp/seconds
metadata, and native string conversion applies only to strings/nulls. AND/OR keep
lazy right-operand evaluation in their nodes. The policy is its own module on top of
`Guardian.Query.ColumnOrConstant`, which keeps only operand representation and
mapping. NativeDispatch keeps its native helpers private and depends on neither
the AST operator nor the scalar function modules.

`Guardian.Timestamp` layers raw date/time reading, canonical field reading and
strict calendar parsing, and owns bounded epoch arithmetic for date addition and
subtraction; each caller keeps its own acceptance rules and null results.

### 5.6 Regular expressions

`Guardian.Query.Regex` is the one place query patterns are compiled and run, on Erlang's `:re`
(PCRE2): the parser validates `RLIKE` and `replace` patterns with it, and evaluation
compiles them again, once per evaluation. Compiled patterns are never put in the AST,
which travels between nodes. (`Guardian.Query.URL` runs `URI.parse/1`'s own fixed
patterns directly, without UTF-8 mode, to find a URL's port; no user pattern goes there.)
Patterns compile in UTF-8 mode without `ucp`, so values
match by character while `\w`, `\d` and `\b` stay ASCII by default (inline `(*UCP)`
changes that). A value that is not valid UTF-8 makes `:re.run` raise; only that call
is rescued, and the value gives null. Every run passes `match_limit` (1,000,000, per
start position) and `match_limit_recursion` (10,000, a depth limit under PCRE2), and
hitting either gives null for that value (`RLIKE`, `NOT RLIKE` and `replace` alike). A pattern may have at most 32 capturing groups:
PCRE2's backtracking frames live in native memory, outside the heap limit, and grow
with the group count, so the cap and the depth limit together bound a run's memory
(security.md 5.2 item 1). `:re` yields to the scheduler during long matches, and the
30-second query limit bounds total CPU.

`replace` takes the offsets of every non-overlapping match (`:global`, with PCRE's
empty-match rules), gives null for a match that starts or ends inside a UTF-8
character (only `\C` can do that), and then appends the untouched slices and the
literal replacement to one binary, stopping once it reaches the 64 KiB string cap
(`Guardian.Query.Text`).
`:re` builds the whole offset list on the calling process's heap, about two matches
per character at worst. A value up to 16 KiB is replaced in the calling process (at
most about 33,000 matches, measured at 10 to 20 MB of process memory). A larger value
is replaced in a helper process spawned with its own `max_heap_size`: the query heap
limit, or 256 MiB when that is 0, so the offsets are bounded even with the limit off.
A helper killed by its cap, or dying any other way, gives null for that value;
anything the helper raises is raised again in the caller. Measured with `x*`,
256 MiB allows about 600,000 matches on one value and 64 MiB about 200,000. The
helper is monitored, not linked, since a link would carry its heap kill to the
caller; its first act is to start a watcher that kills it when the caller dies (a
query stopped at its time limit), so no helper outlives its query. The helper's heap
is on top of its caller's, so a worker's peak can roughly double during a replace.

Streaming the matches instead (one `:re.run` per match, from an offset) keeps no list
but is quadratic: PCRE checks the subject's UTF-8 from the offset to the end on every
call, and `:re` cannot skip the check (40 KB of empty matches took a second).

Guardian used Hyperscan until the hyperscan 0.1.5 NIF's `replace` was found to abort
the VM whenever a pattern's matches grew or overlapped, as `[0-9]+` on "123" does (it
asserted on Hyperscan reporting every match end). `:re` is about 3 to 10 times slower
for `RLIKE`: roughly 2.5 to 10 µs a row for an 89-byte string, against under 1.2 µs.

### 5.7 Query limits

`Guardian.Query.Limits` caps what collects on the coordinator: 100,000 rows and about 64 MiB of
result, the input of an in-memory ORDER BY, and the merge of ORDER BY ... LIMIT; ORDER
BY with a LIMIT above the row cap is refused. Strings that functions build are cut to
64 KiB (`Guardian.Query.Text`), never refused. A query may run for 30 seconds:
`Guardian.Query.run/1` then kills its process, whose links stop every router and worker on
every machine, and raises. Exceeding a cap or the time limit raises `Guardian.Query.Error`,
which both interfaces report with its message. The caps are application environment
values (section 9).

Each process a query runs in also carries a heap limit: `Guardian.Query.Limits.limit_heap/0`
sets `max_heap_size` (`kill: true`, `error_logger: true`,
`include_shared_binaries: false`) to `GUARDIAN_QUERY_MAX_HEAP_MB` (default 256 MiB,
`0` turns it off) on the query process and on every DistributedStream worker, on
whichever node it runs, reading that node's own setting; routers are not limited. A
`:killed` exit from a pipeline or the query process becomes the `Guardian.Query.Error` "a query
process was killed; it may have exceeded its heap limit (GUARDIAN_QUERY_MAX_HEAP_MB);
narrow the query with WHERE, LIMIT or fewer groups" (`Guardian.Query.Failure`). The reason
cannot prove a heap kill, so the message hedges. Shared binaries are left out because
a worker holds references to whole mapped segment files, which would otherwise count
again in every process. In a rolling deploy from a release without the limit, queries
can fail until every node runs the new one, since workers call
`Guardian.Query.Limits.limit_heap/0` on whichever node they start (section 7).

Queries read segments by ID through `Guardian.Storage.segment_row_count/1` and
`Guardian.Storage.get_column/2`, which resolve the ID on every call and use Segment's monitored
readers with no timeout: a slow segment is waited for, and one that is deleted,
expires, crashes, or sits on a node that disconnects fails the query at once with
"segment `id` became unavailable during the query". The exception is a segment whose
copy stops normally while another copy of it is still registered (its in-memory copy
retired after its file loaded, or mid-delete): the read is retried once on that copy
(section 4.2). Storage's own processes use the
same readers with a 5 s timeout. The writer-side calls (`pack`,
`store`, `append`) keep their own timeouts.

These catch accidents, not abuse. The time limit bounds how long a query runs, not how
much memory it takes first. The heap limit bounds each process's own heap, not the
query: GROUP BY state lives in ETS, column data in NIF native memory, shared binaries
are not counted, the check runs at garbage collection so a process can overshoot, and
a query's many processes can each reach the limit. There is no limit on concurrent
queries; a GROUP BY over millions of keys or many concurrent heavy queries can exhaust
memory on every machine at once (security.md section 5.2).

## 6. Interfaces

Authentication, CORS, and what each surface reveals without a key are in
[security.md section 4](security.md#4-b2-api-key). Product behavior is spec section 4.

### 6.1 HTTP server and routing

Bandit serves HTTP on `GUARDIAN_PORT` (default 8080, in development too; an OS-chosen
port in tests). `Guardian.Web.MainRouter` answers `GET /health`, forwards `/api/json` and `/mcp`,
and answers 404 otherwise. Guardian speaks plain HTTP; TLS is the job of whatever sits
in front of it (on Fly, Fly's edge).

### 6.2 JSON API

`Guardian.Web.JsonApi` is a Plug router. Plug order is the important part: CORS (which answers
preflights), then the key check (which notes whether the key came from the header or
the query parameter), then body parsing (JSON only, 8 MB limit), then
routing, then `Guardian.Web.Logger`, then the handler. Checking the key before reading the body
means an anonymous client cannot make the server parse anything.

1. `/send_events` calls `Guardian.Web.Ingest.send_events/1`, shared with MCP, so both
   interfaces validate requests and shape results identically.
2. `/query` calls `Guardian.Web.Query.execute/3` (which has `Guardian.Web.QueryLog` record every query
   and `Guardian.Web.QueryParseErrors` parse failures, section 6.5) around `Guardian.Query.execute/2`, the SQL entry point the MCP tool also uses.
   It resolves the SQL, requires exactly one statement, calls
   `Guardian.Query.run/1` from the request process (which runs the query in its own process),
   and returns labels and rows, which `/query` sends as `{columns, rows}`. A wrong
   statement count or a `Guardian.Query.Error` from running comes back as an error message and
   becomes 400; other exceptions become a bare 500 and log only the failure kind
   and a generated error ID. The JSON router catches application failures before Bandit can
   print their messages or stacks. Unwrapped failures before routing close HTTP/1
   connections rather than draining a body whose reader state is no longer current.
3. `Guardian.Web.Logger` writes a `web_requests` row before the handler and a `web_responses`
   row before the response is sent, for authenticated requests only. Both carry
   `auth_method`, `header` or `query`, from the key check.

Each HTTP request is its own Bandit process, so JSON queries run concurrently. Each
query stops at the 30-second query time limit (5.7); resolving it, which comes first,
is not covered.

### 6.3 MCP

The MCP endpoint uses the Anubis library, pinned at 0.16.0 (reasons in
[dependency pins](#104-dependency-pins)), over Streamable HTTP.
`Guardian.Web.MCP.Router` runs four plugs before handing the request to Anubis's transport:

1. The key check, on every request, so an MCP session carries no authority of its own.
   MCP requests are not recorded in `web_requests`, so when one authenticates with
   the query parameter, the router logs one info line naming the path (never the
   key), at most once a minute per node (`Guardian.Web.Auth.note_query_key_use/1`).
2. A 404 for an unknown or expired `mcp-session-id`, which Anubis 0.16 would
   otherwise accept as a new uninitialized session.
3. A 405 for `GET`, so Guardian never opens a server-push stream and every result
   comes back in its POST response (Anubis 0.16 would send results down a GET stream
   the client may have dropped).
4. For `POST`, reading the body (8 MB limit, else 413) and decoding it as one JSON
   object that is a valid JSON-RPC message, else 400 with a JSON-RPC error (`-32700`
   for undecodable JSON, `-32600` otherwise) and a log line with only the size, a
   reason, and a known method name. The decoded map goes to Anubis as `body_params`,
   which makes Anubis skip its own decoding: Anubis 0.16 logs the whole body of a
   message it cannot decode, crashes on a body over its read limit, and splits
   bodies on newlines (so pretty-printed JSON now works).

Steps 2 to 4 work around Anubis 0.16 behavior and depend on its internals
(`lib/guardian/web/mcp/CLAUDE.md`); recheck them on any upgrade.

`Guardian.Web.MCP.Server` defines the `query` and `send_events` tools and the
`guardian://query-language` resource, which serves `lib/guardian/web/mcp/query_language.md`. A
test fails if a registered function or aggregate is missing from that file.
It registers them on Anubis's frame before every request: Anubis 0.16 keeps
runtime-registered components in its one frame shared by all sessions and clears them
when a DELETEd session it served last ends, so registering once at a client's
`notifications/initialized` left other sessions without tools. This relies on Anubis
internals (`lib/guardian/web/mcp/CLAUDE.md`); recheck on any upgrade.

Anubis 0.16 runs every tool call inside its one server process. A slow query therefore
blocks the execution of every other MCP tool call and protocol request on the machine
(DELETE and the GET rejection never reach that process, and notifications are
acknowledged but processed behind it; security.md section 5.2 item 3), for up to the
30-second query time limit (5.7) plus the schema lookup that resolves the query before
it (up to 60 seconds per table when a machine doesn't answer). Anubis's own 30-second
timeout abandons the caller's wait; the query, which started a little later, stops at
its limit. This is also why parse-error recording must never be synchronous: a stalled
Storage write would stall all MCP tool calls.

### 6.4 Remote console

The release's remote IEx shell attaches to a running node with full VM access (spec
section 4.4). Operators can call `Guardian.Query.execute/1` directly for labels and rows;
these queries are not recorded in `queries` or `query_parse_errors`.

### 6.5 Built-in tables

Guardian observes itself by writing ordinary tables through `Guardian.Engine.log_event/2`
(section 3), so the same query language, retention, and fan-out apply to them (spec section
8 lists their fields):

1. `system_stats`: `Guardian.SystemStats` ticks once a second on a monotonic schedule and
   writes Erlang VM counters. A failed write is skipped (warned once, until a write
   succeeds) rather than crashing it every second. Each row's `host` is the
   machine's hostname (on Fly.io, its machine ID), which tells a cluster's machines
   apart when their hostnames differ; rows carry no Erlang node name.
2. `web_requests` and `web_responses`: `Guardian.Web.Logger`, synchronously in the request. A
   failed write is logged by kind and does not fail the request.
3. `query_parse_errors`: `Guardian.Web.Query.execute/3` catches `Guardian.AST.ParseError`
   from resolution (through `Guardian.Query.execute/2`'s `:on_parse_error` callback),
   builds a bounded row in the request process, and casts it to the
   `Guardian.Web.QueryParseErrors` GenServer unless that GenServer's mailbox already holds about
   100 rows (a best-effort check by the sender); the GenServer applies the hourly
   per-machine cap (60) and writes the row; it reraises the original error so the
   response is unchanged. A failed write or row build is logged by kind and does not
   affect the response. The bounds (spec section 8) keep a flood of bad queries from
   growing the table or delaying responses.
4. `queries`: `Guardian.Web.Query.execute/3` times every query and catches every outcome (a
   result, an error result, or a raise, exit or throw, which it reraises unchanged
   with `:erlang.raise/3`), builds a bounded row in the request process and casts it
   to the `Guardian.Web.QueryLog` GenServer, which writes it through `Guardian.Engine.try_log_event/2`.
   It runs only on the machine that received the request, which coordinates the
   query; peers run plan steps and schema lookups through `Guardian.Query` internals, never
   through `Guardian.Web.Query`, so each query is one row. Writing is an ingest, never a query,
   so there is no recursion. No rate cap; when the GenServer's mailbox already holds
   1,000 rows (a best-effort check by the sender) the row is dropped and counted in an
   atomic the GenServer owns (`:persistent_term`, keyed by its name), which the next
   written row reports as `dropped_before`; the first drop of a backlog logs once, and
   the GenServer re-arms that log once its mailbox falls to half the cap.
   Building, handing off and writing never raise into the request, and failures are
   logged by kind only. Request headers are never recorded: the caller fields are
   `interface`, `remote_ip` and MCP client info. `query_parse_errors` is conceptually
   redundant with it (TODO.md `drop-query-parse-errors`).

## 7. Clustering

Every node is a distributed Erlang node. `rel/env.sh.eex` names it in one of three
modes, and `DNSCluster` (the `dns_cluster` library, started by `Guardian.Application` through
`Guardian.Cluster.discovery_child_spec/1`) finds peers when a discovery name is set:

1. Single node (neither `GUARDIAN_NODE_HOST` nor `FLY_PRIVATE_IP` set): the short name
   `guardian@localhost`, with `ERL_EPMD_ADDRESS=127.0.0.1` and
   `-kernel inet_dist_use_interface {127,0,0,1}`, so epmd and distribution listen on
   loopback only. `bin/guardian remote` and `rpc` work on the machine itself; nothing
   else can reach distribution. There is no discovery and no cookie is required.
   Development and tests also run as single nodes.
2. A cluster on any machines (`GUARDIAN_NODE_HOST=<address>`): the long name
   `guardian@<address>`, with IPv6 distribution (`-proto_dist inet6_tcp`) when the
   address contains `:`. `RELEASE_COOKIE` is required. With `DNS_CLUSTER_QUERY` set to
   a name that resolves to every peer's IP (a Kubernetes headless service, a Docker
   network alias), DNSCluster polls it every 5 seconds and connects to
   `guardian@<each IP>`, asking for AAAA records for an IPv6 node and A records for an
   IPv4 one. Because a peer answers only to its exact name, at boot
   `Guardian.Cluster.discovery_child_spec/1` refuses to start a node whose host is not an IP
   literal, is loopback, or is not written exactly as `:inet.ntoa/1` writes it (for
   example `2001:db8::1`, not the expanded form). Without `DNS_CLUSTER_QUERY` the node
   is a standalone long-named node: it discovers nothing but listens for distribution
   on all interfaces.
3. Fly, the preset of mode 2 (`FLY_PRIVATE_IP` set): the node host defaults to the
   machine's private IPv6 address, so the node is `guardian@<private IPv6>`, and
   `DNS_CLUSTER_QUERY` defaults to `<app>.internal`, whose AAAA records list the app's
   machines. `RELEASE_COOKIE` is required. An operator-set `GUARDIAN_NODE_HOST` or
   `DNS_CLUSTER_QUERY` wins over these defaults. The basename is fixed (not Fly's
   app-plus-image-ref template), so old and new releases stay connected during a
   rolling deploy.

`GUARDIAN_DIST_PORT` optionally pins the distribution listen port (besides epmd's
4369), so a firewall can name it. It applies to the server's `start` and `daemon`
commands only, not to `remote` or `rpc` clients, which would otherwise try to listen
on the same port.

What clustering is used for:

1. Queries: FROM fans out to `Guardian.Cluster.connected_nodes/0` and GROUP BY partitions span
   every node (section 5.4). `connected_nodes/0` is this node plus each peer in
   `Node.list/0` whose `Guardian.Storage.ready?/0` answers `true` within 5 seconds: distribution
   starts before Guardian's applications, so a booting peer is connected while it is
   still loading segments, and asking it would fail every query. Partition workers never
   read Storage, so they also run on a starting node.
2. Metadata: `Guardian.Cluster.Metadata` calls every connected node with `:erpc.multicall`
   (60-second timeout) for its local schemas and adds them. If any node fails or times
   out, the lookup raises `Guardian.Cluster.NodeError` rather than return partial metadata.

What clustering is not:

1. Not replication. Each node stores only the events it received; whatever routes
   requests (on Fly, Fly's proxy) decides which node that is. Losing a node's disk
   loses its events.
2. Not membership. There is no member list, quorum, or failure detector beyond Erlang
   distribution itself. A node that is disconnected or still starting when a query
   starts is simply not asked, so its rows are missing without warning (spec section
   10).
3. Not versioned. Nodes call each other's functions and send closures, so during a
   rolling deploy a query spanning old and new releases can fail with a code mismatch.

Why: the product needs queries to cover all data, not high availability, and Erlang
distribution gives remote calls and process spawning for free. The cost is that a
machine's data is exactly as available as that machine. Who may join, why the cookie
is the whole authentication, and what a self-hosted cluster must keep private is
[security.md section 6](security.md#6-b4-machine-to-machine-clustering).

A cluster of one has no peers to find, which is normal. Multi-node behavior is tested
with local peer nodes (section 11); a two-machine Fly deployment has also been run by
hand, with nodes joining, ingestion landing on both, exact cluster-wide results and
metadata through either machine, and a rolling deploy with no failed or lost ingest
requests.

## 8. Durability and availability, end to end

1. Accepted, not durable: an acknowledged event is in a writable segment in memory.
2. Handoff: within one hour (or at 16,384 rows or 64 MiB), the segment is frozen and
   queued, and the persister writes it within about a second if nothing is ahead of
   it and the write succeeds; a segment whose write fails stays queued in memory.
   The file is fsynced, the directory entry is not (section 4.3).
3. Graceful stop: on SIGTERM the HTTP listener stops, MutableSegments hands off every
   writable segment (10 s budget), PersistedSegments writes everything queued (90 s
   budget), and FullSegments and LoadedSegments stop their segments (5 s each), about
   110 s in all. Whatever stops the VM must wait longer than that before killing it:
   on Fly, `fly.toml`'s 150-second `kill_timeout`, which must stay above the budgets
   plus the tunnel connector's drain (10 seconds, 20 at worst).
4. Crash: a VM crash or out-of-memory kill loses everything not yet written: normally
   about the last hour of each table on that machine plus any persistence lag, with no
   hard upper bound while writes are failing or queued. A host crash or power loss can
   also lose recently written files, since their directory entries are not fsynced.
5. Retention: 15 days from segment creation, then deleted. On Fly, the volume is
   snapshotted daily and 14 snapshots are kept; elsewhere, backups are the operator's.
   Restoring is an operator procedure, and the rescan picks up restored files. Restore a file by writing it under a temporary name
   and renaming it into place: overwriting a mapped file in place can crash the VM.
6. Availability: at startup a machine serves nothing until all its segments are
   loaded. After startup, `Guardian.Application` is `:one_for_one`, so if the Storage subtree crashes
   and restarts, the HTTP listener keeps running and requests that need Storage fail;
   `GET /health` answers 503 until Storage has restarted and reloaded, so a health
   check (Fly's, or a load balancer's) reports the machine unhealthy meanwhile. With
   one machine, every deploy and restart is a short outage for writes and reads;
   producers are expected to retry. With several machines, a proxy that follows the
   health check (Fly's does) routes writes to the others meanwhile, and queries leave
   out the machine until its Storage is ready (section 7).

### Module namespace and restart compatibility

All Guardian-owned modules and protocols live under `Guardian.*`, including
`Guardian.Web.*` and the generated `Guardian.Rules.Compiled.*` pool. External
protocol implementations retain their protocol prefix (for example,
`Enumerable.Guardian.Query.DistributedStream`). Native NIF entry points use the
same Guardian module names. The Mix application and configuration namespace remain
`:guardian`; environment variables, release/node names and disk paths are unchanged.

The transition from unprefixed names requires full release restarts, not a hot-code
upgrade. Segment files contain packed values without module names, and rule files
contain source text plus a JSON write lock. All structs, compiled rule plans, counters,
named ETS tables and persistent terms are VM-local and rebuilt at startup. Existing
files need no migration. Every cluster node must run the same build before
distributed operations can work reliably. See
[the compatibility audit](../changes/guardian-namespace.md).

## 9. Configuration

Configuration is deliberately small. Secrets and deployment values come from the
environment at boot (`config/runtime.exs` and `rel/env.sh.eex`); everything else is a
code default.

Environment variables:

| Variable | Read by | Meaning |
| --- | --- | --- |
| `GUARDIAN_API_KEY` | `config/runtime.exs` | The API key. Required outside tests, at least 32 bytes. |
| `GUARDIAN_ALLOW_QUERY_API_KEY` | `config/runtime.exs` | `true` also accepts the key as the `api_key` query parameter; `false` or unset (the default) never decodes the query string for a key. Any other value fails boot. |
| `GUARDIAN_PORT` | `config/runtime.exs`, `bin/fly-start` | HTTP port, 1 to 65535. Default 8080. Tests use an OS-chosen port. |
| `GUARDIAN_QUERY_MAX_HEAP_MB` | `config/runtime.exs` | Heap limit of each query process, in MiB (5.7). Default 256; `0` turns it off. |
| `GUARDIAN_COUNTER_MEMORY_MB` | `config/runtime.exs` | Positive integer MiB for the asynchronous resident counter memory target (3.5), default 64; empty/invalid refuses startup. |
| `GUARDIAN_DATA_DIR` | `config/runtime.exs` (prod) | Data directory; segments go in `segments/` under it. Default `/root/data`; `/data` in the image and on Fly. Must be writable, and on Fly must be a mounted volume, or boot fails. |
| `GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS` | `config/runtime.exs` | Writable segment age before handoff. Default 3,600,000. |
| `GUARDIAN_NODE_HOST` | `rel/env.sh.eex` | This node's address; setting it makes the node `guardian@<address>`, a cluster member (section 7). Wins over `FLY_PRIVATE_IP`. |
| `DNS_CLUSTER_QUERY` | `rel/env.sh.eex`, `config/runtime.exs` | Discovery name resolving to every peer's IP. Defaults to `<app>.internal` on Fly; unset elsewhere means no discovery. |
| `RELEASE_COOKIE` | `rel/env.sh.eex`, the release | Erlang cookie. Required with `GUARDIAN_NODE_HOST` or on Fly; must match on every node. |
| `GUARDIAN_DIST_PORT` | `rel/env.sh.eex` | Pins the server's distribution listen port, 1 to 65535. Unset means a random port. |
| `FLY_PRIVATE_IP`, `FLY_APP_NAME` | `rel/env.sh.eex`, `config/runtime.exs` | Set by Fly. Their presence selects the Fly preset (section 7) and the volume check. |
| `GUARDIAN_RULES_DIR` | `Guardian.Rules.Config` | The local rule folder (`Guardian.ObjectStore.Local`). Default `<data dir>/rules`; the data folder, a folder containing it, or one inside `segments` refuses startup. |
| `GUARDIAN_RULES_S3_BUCKET`, `_ENDPOINT`, `_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY`, `_REGION`, `_PREFIX` | `Guardian.Rules.Config` | An S3-compatible rule store instead of the folder (3.4). The first four together or none; region defaults to `auto`. Read at boot by Guardian.Rules.Server, not `config/runtime.exs`, so the secret never enters application config. |
| `TUNNEL_TOKEN` | `bin/fly-start` | Optional. Starts the cloudflared connector (10.1); Guardian's own process never sees it. |
| `GUARDIAN_TUNNEL` | `bin/fly-start` | `off` keeps the connector from starting even with `TUNNEL_TOKEN` set (the token is still kept from Guardian), for a machine that should take no tunnel traffic. Any other value, or unset, leaves it on. |

Application environment (`:guardian`), with code defaults; deployments set none of
these except through the variables above:

| Key | Default | Used by |
| --- | --- | --- |
| `api_key`, `allow_query_api_key`, `http_port`, `query_max_heap_mb`, `data_dir`, `dns_cluster_query`, `mutable_segment_max_age_ms` | from the variables above | as above |
| `query_max_result_rows` | 100,000 | `Guardian.Query.Limits` |
| `query_max_result_bytes` | 64 MiB | `Guardian.Query.Limits` |
| `query_time_limit_ms` | 30,000 | `Guardian.Query.run/1` (`Guardian.Query.Limits`) |
| `counter_memory_budget_bytes` | 64 MiB, overridden by `GUARDIAN_COUNTER_MEMORY_MB` | `Guardian.Counters.Store`: asynchronous resident counter memory target (3.5); a non-positive or non-integer value refuses startup |
| `query_parse_errors_per_hour` | 60 | `Guardian.Web.QueryParseErrors` (tests raise it) |
| `rules_store` | from the variables above | `Guardian.Rules.Config` (tests set a store directly) |
| `rules_poll_ms`, `rules_time_limit_ms`, `rules_boot_retry_ms`, `rules_reclaim_after_ms`, `rules_lock_lease_ms`, `rules_save_margin_ms` | 60,000; 1,000; 60,000; 30,000; 120,000; 80,000 | `lib/guardian/rules` (tests shorten them) |
| `object_store_s3_receive_timeout_ms`, `object_store_s3_write_deadline_ms` | 15,000; 20,000 | `Guardian.ObjectStore.S3` (tests shorten them) |
| `persisted_segment_cache_ms` | 600,000 | `Guardian.Storage.PersistedSegments`: how long a written segment's in-memory copy serves before it is stopped (tests shorten it); a value that is not a positive integer stops Storage from starting |

Constants in code that act like configuration: segment capacity 16,384 rows and 64 MiB
budget (`Guardian.Storage.Segment`), 15-day retention (`Guardian.Storage.SegmentExpiration`), 60-second
rescan (`LoadedSegments`), shutdown
budgets (`Guardian.Storage`), the 64-byte table name and 250-byte key limits (`Guardian.Engine`,
`Guardian.Storage.Value`), the 32-byte key minimum (`config/runtime.exs`), the once-a-minute
query-key log line (`Guardian.Web.Auth`), the regular expression match and depth limits
(`Guardian.Query.Regex`), and DistributedStream's 1,000-byte chunks.

Logging: production logs at `info`, set in `config/config.exs` because that file is
compiled into the release (security.md section 8 explains why the level matters).
Tests log at `warning`.

## 10. Deployment and operations

Procedures are in the guides under `docs/guides/`; this section explains how the pieces fit. Guardian is
one release, built into one Docker image, that runs as a single node or as a cluster
(section 7). Fly.io is the best-supported deployment: the repository carries its
`fly.toml`, and on a Fly machine the cluster settings need no configuration beyond the
cookie.

### 10.1 Build

The `Dockerfile` is a two-stage build. The builder (hexpm Elixir 1.19.6 on OTP 28.5.0.8,
Debian trixie) installs a C toolchain, fetches and
compiles production dependencies (cached separately from source), writes the git
commit into `priv/commit` for `Guardian.Build.commit/0`, and builds the release. The runner
image is plain Debian with only the runtime libraries, the release, and a pinned and
checksummed cloudflared binary for the target architecture (one `FROM scratch` stage
per architecture, selected by `TARGETARCH`). Its
CMD is `bin/fly-start`, which starts Guardian (it works the same off Fly). When
`TUNNEL_TOKEN` is set (and `GUARDIAN_TUNNEL` is not `off`), it also runs a cloudflared
connector beside Guardian: an outbound Cloudflare Tunnel, so the operator's Cloudflare
Workers can reach Guardian through a Workers VPC binding instead of the public edge
(security.md B1b). It unsets the token before starting Guardian, and the connector
stays in that script rather than `rel/env.sh.eex`, which runs for every `bin/guardian`
command (`remote`, `rpc`) and would start more connectors.

Cloudflare sends a tunnel request to one of the tunnel's connectors, not to a healthy
origin, so the script keeps the connector serving only while Guardian does. Without a
connector it simply `exec`s `guardian start`. With one, it stays in front of Guardian:

1. It starts Guardian, then the connector only once a socket is listening on
   Guardian's port (read from `/proc/net/tcp` and `tcp6`; the image has no HTTP
   client). The listener opens only after every segment has loaded (section 2.1).
2. On SIGTERM or SIGINT it stops the connector first, which drains in-flight requests
   for up to its 10-second `--grace-period` and disconnects; then it sends Guardian
   SIGTERM and exits with Guardian's status.
3. If Guardian exits on its own, it stops the connector and exits with Guardian's
   status, so the machine restarts. A connector that exits is started again after 5
   seconds; a stop during that pause starts no new one.

A request longer than the drain can still be cut off, a connector still draining after
20 seconds is killed so Guardian's own shutdown isn't held up, and a crash skips the
drain. That a drained connector's new requests go to another machine's connector
follows from Cloudflare's replica routing; it has not yet been observed on a
multi-machine deploy.

The image runs as root, because Fly volumes mount
root-owned and each Fly Machine is a VM whose only workload is Guardian.

Architectures (the one statement of them; other docs point here): the image is built
and run on linux/amd64, which Fly builds. `docker build` targets the host's own
architecture, nothing in the build is x86-only, and the image fetches cloudflared for
its target architecture, so linux/arm64 should build, but it has never been built or
tested (TODO.md arm64-image).

### 10.2 Fly configuration

The repository's `fly.toml` is the maintainer's own deployment and encodes the
operational decisions:

1. One HTTP service on internal port 8080, HTTPS forced at the edge, request
   concurrency soft 200 and hard 250 per machine.
2. Machines never auto-stop, because a stopped machine's events vanish from queries.
3. A health check on `GET /health` every 15 seconds, with a 10-minute grace period
   because boot loads every segment. Deploy with a matching `--wait-timeout`.
4. A volume `guardian_data` at `/data` (10 GB initial, 14 daily snapshots kept).
5. `SIGTERM` with a 150-second `kill_timeout`, so the connector's drain and the
   shutdown persist can both finish.
6. Rolling deploys, one machine at a time, because a volume attaches to one machine.
   No release command, since any machine running the image joins the cluster.
7. VM size `shared-cpu-1x` with 1 GB, one machine; `fly deploy` keeps the current
   machine count.
8. A block of this deployment's overrides, marked for a new deploy to delete:
   `GUARDIAN_ALLOW_QUERY_API_KEY=true` (kept until `web_requests.auth_method` shows
   nothing uses query keys) and `GUARDIAN_QUERY_MAX_HEAP_MB=0`.

### 10.3 Operating

1. Deploys: `fly deploy` builds remotely and replaces machines in place. A failed
   health check stops the deploy without rollback; roll back by redeploying the
   previous image. Elsewhere, replace the container or release and restart it; the
   stop must allow the shutdown budget (section 8).
2. Secrets: set the key, cookie, or optional tunnel token in the environment and
   restart (on Fly, `fly secrets set`, which restarts the machine).
3. Observing: the built-in tables (`system_stats`, `web_requests`, `web_responses`,
   `query_parse_errors`, `queries`) and stdout (on Fly, `fly logs` and `fly status`). Nothing
   alerts.
4. Remote console: `bin/guardian remote` on the node (on Fly,
   `fly ssh console --pty -C "/app/bin/guardian remote"`; in Docker, `docker exec`)
   for direct IEx queries and Storage internals.
5. Scaling: on Fly, `fly scale count` adds a machine with its own volume; scaling
   down detaches a volume and its events drop out of queries. Elsewhere, start another
   node with its own data directory and the cluster settings (section 7).

### 10.4 Dependency pins

`mix.lock` pins the full resolved graph. A few dependencies are held back on purpose:

1. `anubis_mcp` is held at exactly 0.16.0. Guardian's MCP router and server work
   around 0.16 behavior through its internals: the unknown-session 404 uses Anubis's
   private session registry, the `GET /mcp` 405 avoids 0.16 sending results down a
   push stream, and `Guardian.Web.MCP.Server` registers its tools before every request because
   0.16 clears runtime-registered components when a session ends (section 6.3). The
   2.x releases change the protocol, transport, and session APIs, so upgrading is its
   own migration, with session compatibility tests. 0.16 also cannot send MCP server
   `instructions`.
2. `peri` is transitive: Anubis 0.16.0 requires exactly 0.6.2. It moves with Anubis.
3. `hypex` is held at 1.x (`~> 1.1`). Version 2 changes the sketch representation and
   register modules, and `count_distinct` merges sketches across nodes, so an upgrade
   needs numerical regression checks and a plan for clusters running mixed versions.
4. The mmap NIF (`src/mmap.c`, `Guardian.Storage.Mmap`) and DistributedStream
   (`Guardian.Query.DistributedStream`) are vendored, with Guardian's own fixes, and are outside
   Hex updates. Do not reintroduce the `mmap` or `distributed_stream` Hex packages.
5. `req` (`~> 0.7`) is the object store's S3 client (`Guardian.ObjectStore.S3`), for its SigV4 signing; its HTTP
   stack (Finch, Mint) was already in the graph through Anubis.
6. No system library is linked. Hyperscan and libjq were dropped so the build needs
   only a C toolchain; don't add a dependency that needs a system library without
   weighing the install cost.

The image uses Elixir 1.19.6 on OTP 28.5.0.8. See the
[development guide](../guides/development.md) for the local Homebrew toolchain.

## 11. Testing

Tests run locally at commit time, with no hosted CI: the pre-commit hook
(`bin/pre-commit`) runs the checks listed in the
[development guide](../guides/development.md#checks), the full suite among them.
About 150 test files cover:

1. Units per subsystem: tokenizer and parser round trips, every operator, function,
   and aggregation, the column NIF (including golden outputs in
   `test/fixtures/column_nif_outputs.etf`), the segment file format (golden file
   `test/fixtures/segment_file.seg`), flattening, segments, each lifecycle
   manager, mmap, regular expressions (semantics, UTF-8, the backtracking limit),
   query limits (including the heap limit, on one node and on a peer that follows its
   own setting), and worker errors.
2. Concurrency and lifecycle races: handoff visibility, persistence scheduling,
   column release, and a segment column race run in a child VM
   (`test/fixtures/segment_column_race.exs`).
3. Interfaces: the JSON API through `Plug.Test` connections against the real router
   stack (`Guardian.JsonApiTestClient.query/2` in `libtest/guardian/` posts a query),
   and the MCP endpoint end to end through a real MCP client (`Guardian.MCPTestClient`
   in `libtest/guardian/`, an Anubis client started by `Guardian.MCPTestClient.start/0`) against the
   test listener on an OS-chosen port, including sessions, the 404 and 405 rules, and
   authentication with query keys allowed and refused (`Guardian.QueryApiKeys` in `libtest/guardian/`
   switches the setting for `async: false` tests).
4. Clustering: `Guardian.TestCluster` (in `libtest/guardian/`) starts peer BEAM nodes on the same host,
   each running only Storage in its own data directory, and connects them, so schema
   merging, GROUP BY merging of groups split across nodes, node failures, a peer whose
   Storage has not started, and errors on a peer are tested with real distribution.
   Tests with peers run `async: false`, since every query fans out to them.
   DistributedStream's failure protocol is tested (`test/guardian/query/distributed_stream/`)
   on one node (crashes, halts, nested pipelines, a forged marker, workers that exit
   early) and on three (two peers whose connection to each other drops
   mid-pipeline); stage functions that must run on peers live in
   `libtest/guardian/distributed_stream_test_stages.ex`, because test modules are not loaded
   there.
5. Rules: the parser, whole-set validation, semantics through real ingestion, the
   worker's limits, the server (boot refusals, repair, activation, the module pool,
   restarts), both rule stores, and a peer cluster sharing a store; the object-store
   client's S3 and folder implementations, their shared contract and the key lock
   have their own tests. `Guardian.FakeS3` (in
   `libtest/guardian/`) is a small S3 server that checks every request's SigV4 signature with
   its own implementation of the canonical request; `Guardian.RulesTestHelper` restarts the
   shared Guardian.Rules.Server on a test store.
6. Configuration and deployment: `config/runtime.exs` and the production config are
   evaluated in tests, as are the release environment script's three naming modes and
   `GUARDIAN_DIST_PORT`, and `Guardian.Cluster.discovery_child_spec/1`'s record types and
   boot-time name check.

Rules: tests use no external services; each `mix test` run stores segments in a fresh
directory under the system temp directory (set in `config/config.exs`, removed when
the run's VM exits, once Guardian has stopped), so no run sees tables an earlier run
left; `:large` tests (gigabytes of memory) are excluded by default. `Guardian.Query.EvaluationTestCase` is the helper for function
tests; `Guardian.TestHelpers` (in `libtest/guardian/`) resolves and runs SQL (`resolve_sql/1`,
`run_sql/1`), holds shared polling (`eventually/2`, and `eventually_after_gc/1` for
released NIF resources), waits for a call queued at a suspended process
(`await_queued_call/2`, on any node), sets the query time limit for a test
(`with_time_limit/2`), finds processes running pipeline code, picks a full segment's loaded copy
(`loaded_segment/2`, for tests that suspend or kill the segment a query reads),
appends a nested row straight to a segment (`segment_append/2`), writes a segment file
from rows (`write_segment_file/2`), and registers a
one-call fake segment to inject an append's reply (`intercept_append/2`), and
`Guardian.TestCluster.data_root/0` gives a peer a fresh data directory.
`Guardian.TestCluster.single_peer/0` shares a single Storage peer's setup and cleanup
across query tests, preserving the calling setup's test or module lifetime.
Its `await_query_node/1` startup barrier waits for Storage readiness and a GROUP BY
partition lookup; GROUP BY's executor and routing tests share
`Guardian.Query.Executor.group_by_partitions/0`.
`Guardian.TestEnv` (in `libtest/guardian/`) puts `:guardian` application env for an
`async: false` test, on this node or on named peers, and restores it when the test or a
block ends; `with_time_limit/2`, `Guardian.QueryApiKeys.with_query_api_keys/2`,
and `Guardian.CounterBudgetHelper.relax/1` and `scale/1` delegate to it.
`Guardian.WorkBounds` measures caller reductions for synchronous CPU guards, with
bounds calibrated against representative regressions rather than host-dependent
elapsed time (see [unit-test work bounds](../changes/unit-test-work-bounds.md)).
`Guardian.RulesTestHelper.restart_server/2` stops the test server before restoring
the previous store and extra settings through TestEnv. It restarts a previously
running server, leaving a previous failed start stopped until its outer cleanup
restores the original working configuration.
Tests do not use `:global` names: `Guardian.Query.DistributedStream.ClusterTest`
suspends `:global` and checks on teardown that it still registers names. A bare
`assert_receive` waits up to 5 s
(`assert_receive_timeout` in `test/test_helper.exs`), not ExUnit's 100 ms, so tests
need no explicit timeout to wait on another process under load.

Gaps: there is no load or soak test, no automated test of a multi-machine query
against a real deployment (Fly's has been checked by hand, section 7), no test that
runs a cluster from the release with DNS discovery outside Fly, no crash-recovery test
(VM killed with unpersisted data), and peers in multi-node tests run no Web or
Guardian.SystemStats. There are no benchmarks in the tree.

## 12. Known limits

The limits named above, in one place:

1. Storage: corrupt column data aborts the VM (4.3).
2. Storage: a segment whose pack raises at shutdown stops the rest persisting (4.3).
3. Storage: deletion racing persistence can leave a file the next rescan loads (4.2).
4. Storage: the schema misses full and recently persisted segments, and a segment
   dying before Schema registers it crashes LoadedSegments or Schema (4.2, 4.5).
5. Storage: no bound on tables or keys per segment (4.7).
6. Ingest: some event shapes are slow to flatten, and events flatten twice (3.3).
7. Query: no bound on a query's total memory (the heap limit is per process) and no
   concurrency limit (5.7).
8. MCP: one slow MCP call blocks all MCP calls on the machine (6.3).
9. JSON API: parse and resolve errors are a bare 500 (6.2).
10. Parser: a label from `INTERVAL n WEEK` cannot be re-parsed (5.1).

Design limits: one writable segment per table bounds per-table ingest rate (3.2); one
scan worker per node per query (5.4); no replication (7); no directory fsync (4.3);
synchronous request logging (3.3).

## 13. How this was checked

Written from the code: `lib/guardian/application.ex`, every module under `lib/guardian/storage/`,
`lib/guardian/engine.ex`, `lib/guardian/query.ex` and `lib/guardian/query/`, `lib/guardian/web/` and `lib/guardian/web/mcp/`,
`lib/guardian/cluster.ex` and `lib/guardian/cluster/`, `src/*.c` (headers and setup paths of `mmap.c`), `config/`, `rel/`, `bin/fly-start`, `Dockerfile`,
`fly.toml`, `Makefile`, and the test helpers.

When a change alters a structure described here (the supervision tree, the segment
lifecycle or file format, the query pipeline, the interfaces' plug order, clustering,
configuration, or deployment), update the matching section in the same change.

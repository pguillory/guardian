# TODO

Planned changes and known gaps. A change's design goes in `docs/changes/<id>.md`
when it needs one. This file is public: see the change-tracking rules in AGENTS.md.
The maintainer's deployment records (releases, checks, rollback targets) are kept
privately, not in this repository.

## Rules

- [x] rules-no-poll: rules change only through the service, so the one-minute re-read
      and its log line are gone (`docs/changes/rules-no-poll.md`)
- [ ] rules-reread-on-reconnect: for when a cluster is real. A machine that misses a
      reload (disconnected, still booting since rules load before cluster discovery,
      or its reload failed) stays on old rules until the next write or restart.
      Re-reading on join and reconnect is the likely answer.

## Storage and ingestion

- [x] flat-ingest-results: `send_events` returns the stored flat row and
      `return_keys` reads exact columns; nothing rebuilds nested JSON
      (`docs/changes/flat-ingest-results.md`)
- [x] decode-path-hardening: obsolete; flat-ingest-results removed the column-name
      decoder, which only rebuilding used (`docs/changes/bugs-03.md`)
- [x] ingest-idempotency: optional client keys suppress matching same-node batch
      retries with short-lived, bounded in-memory receipts; availability first
      (`docs/changes/ingest-idempotency.md`)
- [ ] ingest-idempotency-cluster: route keyed ingests to an owner so retries through
      different nodes can share receipts; define membership/failure behavior
- [x] pack-timeout-logged: a full segment that does not answer a pack step within
      its call timeout is logged once at error level and retried, like a failed write,
      instead of retrying silently (`docs/changes/fail-closed-findings.md`)
- [ ] harden-shutdown-persist: a segment whose pack raises during shutdown (an
      unexpected reply such as `{:error, :not_frozen}` fails a match) aborts persistence
      of every remaining full segment
- [ ] full-segments-crash-cascade: if FullSegments crashes, Storage's `:rest_for_one`
      stops MutableSegments, whose `terminate/2` hands its segments to the dead
      FullSegments and crashes, so every unpersisted mutable row is lost, acknowledged
      events included; PersistedSegments' `terminate/2` crashes the same way on
      FullSegments' missing table and skips `retire_all`. docs/architecture/system.md
      2.1 documents the row loss as the cascade; whether that is acceptable, and
      whether terminate should crash on that path, is undecided. Normal shutdown stops
      in the safe order and is unaffected
- [ ] segment-count-columns: segment files still carry six per-type count columns
      (null, false, true, int, float, string) that nothing reads; dropping them changes
      the format, so it needs a format version and a migration plan
- [ ] serialize-segment-deletion: deleting a segment while it is being persisted, or
      after its file is written but before LoadedSegments registers it, leaves a file
      the next restart loads again
- [ ] segment-schema-gaps: the schema (SHOW TABLES, DESC, the schema table, SELECT *)
      misses segments that are full or persisted but not yet loaded, and a segment
      that dies between LoadedSegments starting it and Guardian.Storage.Schema registering it
      crashes them (docs/architecture/system.md 4.2 and 4.5)
- [ ] reject-oversized-events: reject, never partly store, an event whose flattened
      row has more than 1,000 columns or 1,000,000 slots, reporting it as that event's
      failed result
- [ ] segment-slot-and-column-caps: cap a mutable segment's columns and slot area
      before each append, beside today's row and byte caps
- [x] rules-builtin-tables: built-in table names take rule files and LOOKUP FROM like
      any other table; rules run on API-ingested rows and Guardian's own writes to
      its built-in tables never run them (`docs/changes/rules-builtin-tables.md`)
- [x] object-store-lock: the rule write lock and the S3 client move out of Rules into
      a generic object-store client (`Guardian.ObjectStore`), with a lease lock on any
      key; Rules is one caller, with no behavior change (`docs/changes/object-store-lock.md`)
- [x] rules-store-fold: stores declare sharing through ObjectStore; Server owns
      the remaining rule lock policy, preserving behavior (`docs/changes/rules-store-fold.md`)
- [x] atomic-write-helper: segment files and the local rule folder share one leaf
      temp-file, fsync, rename writer (`Guardian.AtomicFile`); local rule and lock
      writes are now fsynced too (`docs/changes/atomic-write-helper.md`)
- [x] object-store-local: a generic folder object store, with the rule folder's
      listing and key policy moved into Rules; a local rule folder is read like a
      bucket (`docs/changes/object-store-local.md`)
- [x] s3-write-deadline-check: expose the S3 write deadline and check that Rules'
      default save margin exceeds it (`docs/changes/s3-write-deadline-check.md`)
- [x] local-store-lock-id: a local folder store's conditional puts are serialized
      per folder on this node; its lock had named the folder as the requester, so
      concurrent writers all held it at once (`docs/changes/local-store-lock-id.md`)
- [x] exception-policy: expected outcomes are data and anything else raises; catches
      are rare and each names its reason (CONTRIBUTING.md, `docs/changes/exception-policy.md`)
- [ ] query-error-as-data: have the Resolver return `Query.Error` instead of raising it,
      removing `Guardian.Query`'s two rescues
- [x] counter-rescues: `Guardian.Counters.Store` validates request options instead of
      rescuing them and keeps one documented catch-all as its fail-open boundary;
      Transport's routing no longer rescues programming errors (code review follow-up)
- [x] counter-transport-malformed-op: refuse noninteger anchored increment/CAS
      expiries before routing and admission, preserving sibling operations and
      failed-wait allowance (`docs/changes/counter-transport-malformed-op.md`)
- [x] local-store-lock-identity: a local folder store's write lock is keyed by the
      folder's device and inode, taken in `new/2`, so `dir`, `dir/`, a relative path
      or a symlink to one folder share it (follow-up to local-store-lock-id)
- [x] rule-lock-once: the rule write lock is tried once and a held lock fails at once as
      busy; the only retry, a few seconds, is in the MCP write_rule and delete_rule tools
      (`docs/changes/rule-lock-once.md`)
- [x] lock-age-unknown: an S3 response without a Last-Modified Guardian can parse
      gives no object age instead of 0, and a held lock of unknown age fails the
      acquire with an error rather than reading as busy forever
      (`docs/changes/fail-closed-findings.md`)
- [x] cas-integer-token: Counters.Store CAS tokens are one random integer and Store
      follows memcached's add/cas names and answers (`docs/changes/cas-integer-token.md`)
- [x] local-store-lock-races: pin concurrent ETag puts and local lease creation/takeover;
      document unbounded contention and defer queued locking while Rules.Server is
      the only production writer (`docs/changes/local-store-lock-races.md`)
- [x] ingest-rules: SET and UNSET rules stored as files (`<table>/<name>.gsql`, in a
      folder or an S3-compatible bucket), run on API ingests before storage, managed
      through MCP tools with whole-set validation and a store-held write lock
      (`docs/changes/ingest-rules.md`)
- [x] rules-rollout: put rules into the maintainer's deployment (`fly.toml`), each
      step only on the maintainer's go, and each after the one before is checked
      1. Deploy the rules engine with no rules settings. Done (2026-10-24).
      2. Bucket: an R2 bucket and a bucket-scoped object read/write token, made by
         the maintainer; the secret goes straight into the deployment's secrets,
         never printed or stored here. Check the credentials from the deployment's
         own network as `docs/guides/rules.md` ("Switching an existing deployment to
         a bucket") describes, conditional writes included (a second
         `If-None-Match: *` create gets 412).
         Done (2026-10-26).
      3. Switch: stage every `GUARDIAN_RULES_S3_*` setting (bucket, `https://`
         endpoint, key ID and secret, plus a prefix if used) and apply them in one
         restart.
         Copy any rules from `/data/rules` into the bucket first. Checks: the boot log
         names the bucket, `list_rules` shows the copied rules, and a test write and
         delete through the MCP tools succeed. Rollback: remove them all together,
         in one restart (removing some refuses startup); `/data/rules` stays.
         Done (2026-10-26).
- [x] rules-track-lookup: TRACK (counters) and LOOKUP statements; settled v1 design
      and reviewed four-piece plan in `docs/changes/ingest-rules.md`
      1. [x] C1: node-local ETS get/gets/cas/incr, per-key TTLs, memory
         budget and oldest-half eviction (superseded by counter-store.md below)
      2. [x] C2: consistent owner hashing, bounded remote operations and fail open
      3. [x] C3: mergeable count, distinct (HyperLogLog), sum, min, max and avg
      4. [x] C4: TRACK/LOOKUP grammar, validation, bucket policy and rule execution
         C4 is split into C4a/b/c; counter statements are enabled.
         1. [x] C4a: parsed syntax, AST, canonical source and traversal; RuleSet
           initially rejected counter statements before building executable steps
         2. [x] C4b: validation, dependencies, resolved identities and pure coherent
           reload selection; counter statements were still refused at this checkpoint
           - [x] Prerequisite: separate typed steps, scalar validation and dependency ordering
         3. [x] Prerequisite: quiet expiry catches up in immediate pages and
           reclaims expiry before live eviction; counter crash loops are isolated
           from Guardian.Application, with automatic backoff recovery and availability metrics
         4. [x] C4c: execution, buckets, arrival metadata, limits/config, live coherent
           reloads/restart metadata and product docs
           1. [x] C4c1: Server activation selection, bounded recoverable module-plan
             metadata and unresolved-candidate compiler refusal; counters stayed disabled
           2. [x] C4c2: internal execution, buckets, private arrival metadata and
             shared event/batch budgets; both counter gates remain closed
           3. [x] C4c3: enable both gates together, live counter reload/restart and
             HTTP/MCP return_keys coverage, memory config and full feature docs
- [x] counter-batching: run dependency levels through nested key state machines,
      with concurrent owner pipelines and existing fail-open budgets
      (`docs/changes/counter-batching.md`)
- [x] counter-capacity-reclamation: direct atomic public-ETS operations with
      housekeeping-only expiry and sampled earliest-expiry eviction; the configured
      memory target is enforced asynchronously (`docs/changes/counter-store.md`)
- [x] shared-aggregates: queries and counters use the same per-aggregate modules,
      with explicit counter opt-in and preserved defaults, precision and numeric
      policies (`docs/changes/shared-aggregates.md`)
- [x] counter-merge-order: merge order is no longer a promise; min/max ties are
      undefined and order-sensitive float results may vary, with no rounding
      (`docs/changes/counter-merge-order.md`)
- [x] counter-retirement: remove legacy scalar cluster entry points and the
      counter aggregate adapter; carry resolved shared aggregate configurations
      through rule plans and batched execution (`docs/changes/counter-retirement.md`)
- [x] counter-client: split the batched Client facade from Transport and Budget,
      preserving counter behavior (`docs/changes/counter-client.md`)
- [x] counter-definition-preparation: prepare immutable TRACK definitions once and
      centralize legacy hash-field selection without changing identities or results
      (`docs/changes/counter-definition-preparation.md`)
- [x] counter-definition-single-source: keep TRACK metadata only in CounterDefinition
      and select shared aggregates by name, preserving identities and plan hashes
      (`docs/changes/counter-definition-single-source.md`)
- [x] plan-hash-determinism: encode resolved LOOKUP plan hashes deterministically so
      they match across VM starts, without changing counter identity or base hashes
      (`docs/changes/plan-hash-determinism.md`)
- [x] counter-event-context: type the private Client context and isolate transport
      backend injection in a test-only adapter (`docs/changes/counter-event-context.md`)
- [x] counter-execution-topdown: counter execution reads top-down in
      `Rules.CounterRuntime` (run_counters, run_state_machines, run_one_iteration)
      over generic `Guardian.Lists` reshaping; Client routes and dispatches owner
      batches; operations within an owner's pipeline now go in input order
      (`docs/changes/counter-execution-topdown.md`)
- [x] counter-execution-layer: counter execution moves from Rules.CounterRuntime
      to `Guardian.Counters.Execution` in the counters layer; Rules.Runtime prepares
      statements and writes results; Execution owns owner dispatch order; client
      tests run through the real round loop (`docs/changes/counter-execution-layer.md`)
- [x] counter-client-fanout: Execution hands one list of operations to
      `Client.batch/2`, which routes, groups, runs owners in parallel and restores order;
      the injected dispatch function goes, and Execution's tests run on the real Client,
      async through per-event budgets (`docs/changes/counter-client-fanout.md`)
- [x] counter-operation-structs: named TrackOperation and LookupOperation structs
      replace the `{:track, ...}` and `{:lookup, ...}` tuples
      (`docs/changes/counter-operation-structs.md`)
- [x] counter-machine-nil-operation: reject nil initial and next operations instead
      of silently treating a malformed callback transition as completion
      (`docs/changes/counter-machine-nil-operation.md`)
- [x] counter-definition-layer: the counter definition and arrival coordinates
      move into Counters (`Counters.Definition`, `Counters.Arrival`); Execution
      takes ops, an Arrival and a Counters.Context and names no Rules module;
      `Execution.missing/1` is replaced by `Aggregation.default/1` of
      `Definition.aggregation/1`; plan hashes unchanged; CounterRuntimeTest splits
      into ExecutionTest and CounterRulesTest
      (`docs/changes/counter-definition-layer.md`)
- [x] rules-compiler-metadata: share compiled execution levels and reconstruct
      exact flat plan metadata only for activation, without per-event rebuilding
      (`docs/changes/rules-compiler-metadata.md`)
- [x] rules-publisher: extract synchronous activation/publication and module-pool
      ownership from Server without changing behavior (`docs/changes/rules-publisher.md`)
- [x] invalid-rules-fail-events: invalid stored rules fail their events at boot and
      on reload alike, with no last good rules, connected components or invalid-rules
      log line; an unreachable store at boot is retried until it answers
      (`docs/changes/invalid-rules-fail-events.md`)
- [x] rules-reclaim-deleted-once: a Server restart retires a pool name that has only
      old code as already deleted, so reclamation soft-purges it without deleting it
      again (which made the code server report that it must be purged first)
- [x] plan-canonical-steps: keep only flat steps in Rules.Plan and derive execution
      levels at compile time, without changing order, hashes or plan recovery
      (`docs/changes/plan-canonical-steps.md`)
- [x] aggregation-finish: centralize list-result storage validity at the shared
      finish boundary without changing scalar or counter policies
      (`docs/changes/aggregation-finish.md`)
- [x] rule-clause-rendering: rule statements share BY/WHERE rendering without
      statement-to-statement helper calls; canonical source stays byte-identical
      (`docs/changes/rule-clause-rendering.md`)
- [x] counter-routing-phash2: replace custom routing encoding and SHA-256 scores
      with phash2 rendezvous scores; stored typed keys remain distinct
      (`docs/changes/ingest-rules.md`, C2)
- [x] aggregates-unify: every aggregate is a counter operator, with one empty
      mergeable state and one configuration for queries and counters (p8 distinct,
      null empty sum, raw count, exact empty average) (`docs/changes/aggregates-unify.md`)
- [x] counters-monotonic-clock: `Guardian.Counters.Clock` holds the microsecond
      clock/deadline helpers Context, Budget and Transport share, making their unit
      coupling explicit (`docs/changes/counters-monotonic-clock.md`)
- [x] clock-as-data: Store, IngestIdempotency and QueryParseErrors take the current
      time as a required argument instead of a `:clock` function option
      (`docs/changes/clock-as-data.md`)
- [x] function-test-seams: no function-valued test options remain: QueryParseErrors'
      and QueryLog's `:writer` and `Guardian.Web.Query.execute/3`'s `:execute` are gone
      (`docs/changes/function-test-seams.md`)
- [x] rules-open-questions: the failure and invalid-at-boot defaults are confirmed
      and their switches (`:rules_on_failure`, `:rules_invalid_at_boot`) removed
- [x] rules-server-redaction: Guardian.Rules.Server's formatted status and crash reports
      never show rule text (`format_status/1`, and callbacks re-raise only a kind)
- [x] rules-s3-loopback-http: the S3 rule store endpoint accepts `http://` only for
      `localhost`, 127.0.0.0/8 or `[::1]`; any other host must use `https://`
- [x] rules-store-429: a rate-limited (HTTP 429) rule store at boot is retried like
      an unreachable one, rather than refusing startup at once
- [x] rules-row-index: each SET and UNSET scanned every column of the event, and a
      read without an exact key walked that name's case variants, present or removed;
      the row is now indexed once per event
- [x] engine-single-flatten: obsolete; since flat-ingest-results Engine flattens each
      event once and returns the stored row
- [x] fix-unflatten-nil-list-items: obsolete; flat-ingest-results removed unflattening
- [ ] bound-flattened-cells: a list of objects whose items each have their own keys
      flattens into one nil-padded column per key, quadratic in the list's length
      (20,000 items of about 300 KB took 148 s); bound distinct paths or total
      flattened cells per event at validation time
- [ ] raise-list-depth: columns hold lists of lists but not deeper
      (`MAX_COLUMNS_PER_STACK = 3`); raising it is one-way for old readers and needs a
      format-compatibility test
- [ ] remove-key-size-limit: Engine drops fields whose flattened key exceeds 250
      bytes; lift it once key and schema memory is bounded (check `Guardian.Cluster.Metadata`)
- [ ] column-nif-dirty-schedulers: `to_list`, `filter`, and packing over 64 MiB
      columns run for tens of milliseconds on normal schedulers
- [ ] validate-packed-columns: unpacking a corrupt segment file aborts the VM through
      asserts instead of returning an error
- [ ] sweep-stale-temp-segments: a crash between writing and renaming a segment leaves
      its `{final}.{n}.tmp` file in the segment directory forever (ignored by the
      loader); remove stale temp files at startup
- [x] nif-stub-list: `Guardian.Storage.Column.NIF` generates its stubs from one
      name/arity list that mirrors `nif_funcs[]` in `src/column.c`, plus the existing
      `get_value/2` stub
- [x] remove-column-get-value: remove the column `get_value` API, which had no C
      implementation, and test that the NIF stubs match `nif_funcs[]`
      (`docs/changes/remove-column-get-value.md`)

## Queries

- [x] case-sensitive-identifiers: field, column and table names keep their case and
      match exactly; rule field names are flat, SET and UNSET act on exactly the named
      column, and RowIndex and the ambiguous-column error are gone
      (`docs/changes/case-sensitive-identifiers.md`)
- [x] query-dispatch-policy: centralize scalar/native selection and metadata
      eligibility without changing query results (`docs/changes/query-dispatch-policy.md`)
- [x] native-dispatch-boundary: extract the scalar/native operation policy from
      ColumnOrConstant into NativeDispatch and narrow the generic map/native helper
      API, removing unused ternary native dispatch (`docs/changes/native-dispatch-boundary.md`)
- [x] rendezvous-single-module: one leaf `Guardian.Rendezvous` serves counter ownership
      (mapping unchanged) and GROUP BY partition routing, which gains a tie-break
      (code review follow-up)
- [x] groupby-peer-merge-test: a peer-cluster test puts rows for the same one- and
      two-column groups on two nodes, with groups owned by each node, and asserts one
      merged row per group (code review follow-up)
- [x] evaluation-alias-block: consolidate Evaluation's two alias blocks into one
      sorted block after its moduledoc (code review follow-up)
- [x] timestamp-offsets: time arithmetic and epoch conversion accept only UTC
      `YYYY-MM-DD HH:MM:SS`; numeric offsets and other formats give null
      (`docs/changes/timestamp-offsets.md`)
- [x] timestamp-arithmetic-helper: share timestamp readers and date_add/date_sub's
      bounded arithmetic without double parsing or changing caller acceptance
      (`docs/changes/timestamp-arithmetic-helper.md`)
- [x] timestamp-to-seconds-nonraising: `to_seconds` uses the nonraising
      `Guardian.Timestamp.parse_seconds/1` instead of catching exceptions; the raising
      `Guardian.Timestamp.to_seconds/1` is unchanged, since removed (code review follow-up)
- [x] rescue-catchall-cleanup: remove the unused raising `Guardian.Timestamp.to_seconds/1`
      (`parse_seconds/1` is the conversion); `url_port` catches only `system_limit`
      (a port of over about 1.26 million digits) and `cosine_similarity` returns null
      for lists of different lengths and catches only `badarith`; query results are
      unchanged (code review follow-up)
- [x] url-parse-totality: the `url_*` functions parse through the nonraising
      `Guardian.Query.URL.parse/1`, which never converts a port of more than 20 digits,
      so a URL with a port too long for `URI.parse/1` no longer fails the query
      (`docs/changes/url-parse-totality.md`)
- [x] url-result-copy: for a port too long to convert, `Guardian.Query.URL.parse/1`
      copies every string field, so a short `url_*` result no longer keeps the up to
      8 MB cut value alive (follow-up to url-parse-totality)
- [x] format-timestamp-names-nonraising: unknown month/hour names give null through
      fallback lookups instead of a rescued `CaseClauseError`, keeping the terminal
      cap and invalid-name behavior (code review follow-up)
- [x] regex-on-re-drop-jq: `replace()` with growing or overlapping matches aborted the
      VM in the Hyperscan NIF; regular expressions now run on `:re` with backtracking
      limits, and jq() and the Hyperscan and libjq dependencies are gone
      (`docs/changes/regex-on-re-drop-jq.md`)
- [x] query-log: every JSON and MCP query is recorded in the built-in `queries`
      table, once on the coordinating machine (`docs/changes/query-log.md`)
- [ ] drop-query-parse-errors: `queries` records every parse failure too (with
      `error_kind = 'parse'`, without the hourly cap); drop `query_parse_errors` and
      its recorder, moving `truncate/2` to `Guardian.Utils` and the caller helpers to a small
      `Guardian.Web.Caller` module
- [x] replace-offset-memory: `replace` held every match offset of a value with no
      bound when `GUARDIAN_QUERY_MAX_HEAP_MB=0`; a value over 16 KiB is now replaced in
      a helper process with its own heap cap (`docs/changes/replace-offset-memory.md`)
- [x] total-functions: functions and operators return null instead of failing,
      integers wrap to 64 bits on both evaluation paths, aggregates that overflow are
      null, every value has a string form, and built strings are cut to 64 KiB; a
      query behavior change (`docs/changes/total-functions.md`)
- [x] timestamp-arithmetic-columns: a timestamp string plus or minus an integer added
      the seconds per event, but over two columns the NIF gave null; `+` and `-` now
      evaluate per value when one column holds strings and the other integers
- [ ] arm64-image: build and test linux/arm64 locally too, which
      should work now that Hyperscan is gone but has never been built
- [x] query-heap-fixed: each query process has a fixed 256 MiB heap limit;
      `GUARDIAN_QUERY_MAX_HEAP_MB` and its off mode are gone
      (`docs/changes/query-heap-fixed.md`)
- [ ] query-memory-bound: result sizes, string sizes, run time and each query
      process's heap are bounded, but a query's total memory is not (GROUP BY state in
      ETS, column data in native memory, many processes); a deliberate or exotic query
      can still exhaust a machine and lose its unpersisted events
- [ ] list-field-paths: let `users.name` find the list column `users..name`
- [x] select-schema-on-demand: only `SELECT *` looks up table schemas while
      resolving; other SELECTs make no cluster schema call before they run
      (`docs/changes/select-schema-on-demand.md`)
- [x] select-star-without-table: `SELECT *` with no FROM, or a FROM that is not a
      table name, crashed resolution (an internal error); it is now a query error
- [x] query-input-errors: a FROM or DESC that is not a table name (`FROM 1`,
      `FROM '_stream'`, also through LET) and a LET function given the wrong number of
      arguments are query errors, not internal ones; a LET name standing for `*` labels
      each column with its name instead of one label for all of them
- [ ] statement-node-set: compute a statement's node set once, so a hung peer's 5 s
      readiness check is paid once per query and a `SELECT *`'s resolve and FROM see
      the same nodes
- [x] json-query-error-responses: obsolete; split-api-keys removed JSON `/query`
      (`docs/changes/split-api-keys.md`)
- [x] not-in: `x NOT IN [...]` did not parse (only `NOT x IN [...]`); it is now the
      infix negation, like NOT LIKE (`docs/changes/not-in.md`)
- [x] in-parenthesized-list: `x IN ('a')` was IN over a grouped string, null, so a
      rule using it silently never matched; a parenthesized list after IN is now the
      parse error "IN takes a list in square brackets" (`docs/changes/in-parenthesized-list.md`)
- [x] integer-literal-range: an integer literal outside int64
      (`99999999999999999999`, or `-9223372036854775808`, which is minus applied to
      2^63) parsed, then failed evaluation; it is now the parse error "Number out of
      range" (`docs/changes/integer-literal-range.md`)
- [x] interval-arithmetic-overflow: an in-range `INTERVAL n WEEK` whose seconds
      overflow int64 (`INTERVAL 15250284452472 WEEK`), constant arithmetic that
      overflows (`15250284452472 * 604800`), and `interval('<huge>w')` failed the
      query with "argument error"; total-functions fixed it: such intervals are null,
      and integer arithmetic wraps to int64
- [ ] interval-round-trip: `INTERVAL 2 WEEK` unparses to `interval('2w')`, which does
      not parse (INTERVAL is a keyword), so its column label cannot be re-parsed
- [ ] function-behaviour: an optional `Guardian.Query.Function` behaviour for function
      modules, with `eval2/2` as an optional callback, so the compiler checks a
      module's entry points (`lib/guardian/query/function/AGENTS.md`)
- [x] test-only-labels: `Guardian.Query.labels/1` (SQL text) and the SHOW/DESC clauses of
      `Guardian.Query.Resolver.labels/1` are reached only from tests, since the Resolver
      rewrites SHOW and DESC first; drop them and test SHOW/DESC labels through
      `Guardian.Query.Resolver.resolve/1` (`docs/changes/query-tidy.md`)
- [x] query-tidy: declare Query's public boundary, move `merge_take/4` to
      `Guardian.Lists`, and test a consumer's normal exit mid-pipeline
      (`docs/changes/query-tidy.md`)
- [ ] resolver-test-only-functions: `Guardian.Query.Resolver.unresolve_statement_index/2,3`
      has no caller outside tests, and the binary clause of `resolve_aliases/1` and the
      public `resolve_show_desc/1` are reached only from tests or the module itself;
      drop them or make them private, testing through `resolve/1`. Likewise
      `Guardian.Query.Function.Interval.from_seconds/1` has no caller but its test;
      drop it with its test
- [x] worker-error-collector-fail-closed: a query whose worker error collector is gone
      fails instead of reading as "no error", and a worker waits for its report's
      acknowledgement with no timeout, so a lost report cannot give a partial answer
      (`docs/changes/fail-closed-findings.md`)
- [ ] ready-check-timeout: `Guardian.Cluster.connected_nodes/0` silently leaves out a
      connected peer that does not answer the 5-second readiness check (or fails it),
      from every query and schema lookup, so a query returns 200 missing that peer's
      rows. The spec states this only for `SELECT *` resolution (section 4's timeout
      paragraph); section 10 item 6 covers only disconnected and still-starting nodes.
      Options: (a) fail closed: a connected peer that times out or errors fails the
      query or lookup with a node error, while not-ready and disconnected peers stay
      left out, with matching spec changes; (b) keep dropping it for availability and
      say so in section 10 item 6. A cluster availability decision for the maintainer

## Interfaces and operations

- [x] split-api-keys: an insert-only ingest key (`GUARDIAN_INGEST_API_KEY`) works
      only on `POST /api/json/send_events`; a full-access admin key
      (`GUARDIAN_ADMIN_API_KEY`) is for MCP; `POST /api/json/query` is removed; the
      single `GUARDIAN_API_KEY` stays full access, deprecated, until it is retired
      (`docs/changes/split-api-keys.md`)
- [x] plain-setup: the README's setup links the Fly guide instead of copying its
      commands; the guide lets `fly launch` write `fly.toml`, with a two-line hand edit
      for the stop settings, and sets the keys with `fly secrets set`; the README's
      helper is `send_event` in Python (`docs/changes/plain-setup.md`)
- [x] readme-guide-copies: the README's Fly commands are the Fly guide's, and a test
      checks that they match; the Docker steps and "What it isn't" copies are gone;
      superseded by plain-setup (`docs/changes/readme-own-client.md`)
- [x] readme-own-client: the README drops the official clients; readers write a small
      `event(table, fields, returning=...)` helper (Python, JavaScript) over
      `send_events`; setup is three steps (deploy on Fly, send an event, connect
      Claude Code); "What it isn't" is gone; superseded in part by plain-setup
      (`docs/changes/readme-own-client.md`)
- [x] readme-walkthrough: the README walks through one example in three parts
      (send events and ask an agent, block with a rule, rate limit with a TRACK
      counter), with running and connecting after it (`docs/changes/readme-walkthrough.md`)
- [x] drop-legacy-api-key: `GUARDIAN_API_KEY` is no longer read; a deployment that
      sets only it refuses to start with an error naming `GUARDIAN_ADMIN_API_KEY` and
      `GUARDIAN_INGEST_API_KEY`, and beside the admin key it is ignored
      (`docs/changes/drop-legacy-api-key.md`)
- [x] dev-random-admin-key: a local dev Mix run without `GUARDIAN_ADMIN_API_KEY`
      generates a random one and prints it; releases build only with `MIX_ENV=prod`
      and still refuse to start without it (`docs/changes/dev-random-admin-key.md`)
- [x] fly-example-config: the repository carried `fly.example.toml`, a template; a
      deployment's own `fly.toml` is gitignored or kept outside the tree; superseded
      by fly-commands-guide (`docs/changes/fly-example-config.md`)
- [x] fly-commands-guide: the Fly guide builds `fly.toml` with `fly launch` flags and
      one marked addition for what flyctl can't set, and saves the generated keys;
      superseded by plain-setup (`docs/changes/fly-commands-guide.md`)
- [x] fly-check-grace: the health check's grace period is 1 minute, Fly's cap; the
      deploy's `--wait-timeout` is what waits for a slow boot; since plain-setup, only
      in the Fly guide's Scaling section (`docs/changes/fly-check-grace.md`)
- [x] query-api-key-off: keys are accepted only in the `x-api-key` header;
      `GUARDIAN_ALLOW_QUERY_API_KEY` and `web_requests.auth_method` are gone
      (`docs/changes/query-api-key-off.md`)
- [ ] reserve-builtin-tables: refuse built-in table names (`queries`, `web_requests`,
      `system_stats`, ...) on API ingest, so the ingest key cannot forge Guardian's
      own rows (`docs/changes/split-api-keys.md`)

- [x] rules-docs-structure: split Rules invariants into single-purpose requirements
      and add stable spec subsection links (`docs/changes/rules-docs-structure.md`)
- [x] rules-idempotency-docs: link repeated rule and retry requirements to their
      canonical homes, preserve product tiers and change history, and mark aggregate
      policy supersessions (`docs/changes/rules-idempotency-docs.md`)
- [x] agent-instruction-tutorials: move the query-function tutorial and column
      reference into docs/, retaining short mandatory editing rules and pointers
      (`docs/changes/agent-instruction-tutorials.md`)

- [x] engine-fun-frame: preserve per-event failure handling when a caught failure
      carries a BEAM fun stack frame (`docs/changes/failure-diagnostics.md`)
- [x] failure-diagnostics: share value-free failure classification and stack
      redaction across ingestion, rules, counters and Web diagnostics
      (`docs/changes/failure-diagnostics.md`)
- [x] ingest-outcome-mapping: idempotency returns plain outcomes that Web.Ingest maps
      to HTTP/MCP replies, a shared JSON query test client, and removal of the
      Engine/Storage failure-classification delegates
      (`docs/changes/ingest-outcome-mapping.md`)
- [x] bugs-03: worktree-safe hook installation, conservative rules crash-frame
      redaction, deterministic segment timer coverage, and JSON failure logging
      without exception data (`docs/changes/bugs-03.md`)
- [x] guardian-alias-readability: use local aliases in dense repeated module call sites
      (`docs/changes/guardian-namespace.md`)
- [x] guardian-test-module-names: align legacy test declarations with their subsystem
      paths (`docs/changes/guardian-module-paths.md`)
- [x] canonical-agent-instructions: use real AGENTS.md files throughout, remove
      the former instruction filename and symlinks, and check required subsystem
      coverage (`docs/changes/canonical-agent-instructions.md`)
- [x] agent-instruction-link-regression: originally checked instruction symlinks;
      superseded by canonical-agent-instructions
      (`docs/changes/nested-agent-instructions.md`)
- [x] nested-agent-instructions: originally exposed nested rules through symlinks;
      canonical-agent-instructions replaces the links and retains the ancestor read rule
      (`docs/changes/nested-agent-instructions.md`)

- [x] guardian-module-paths: align source, test and compiled-helper paths under
      `guardian/`, preserving subsystem test grouping and updating all path references
      (`docs/changes/guardian-module-paths.md`)
- [x] guardian-application-name: rename the application callback to
      `Guardian.Application` after the path moves (`docs/changes/guardian-module-paths.md`)
- [x] guardian-namespace: qualify every owned module under `Guardian.*`, including
      web modules, native entry points and the compiled rule pool; preserve disk
      formats and document full-restart compatibility (`docs/changes/guardian-namespace.md`)
- [x] remove-console: remove the custom table printer and VM-stop helper; keep the
      release's remote IEx shell (`docs/changes/remove-console.md`)
- [x] plug-crypto-221: update the crypto dependency to 2.2.1 for CVE-2026-105963
      (`docs/changes/plug-crypto-221.md`)
- [x] bandit-114: update Bandit to 1.14.0 for HTTP parser and resource-limit fixes,
      preserving Guardian's API behavior (`docs/changes/bandit-114.md`)
- [x] image-refresh-1027: update cloudflared to 2026.10.5 (Go 1.27.3) and the Debian
      base to trixie-20261027 for upstream fixes, and delete the stale branch `11642`
      (`docs/changes/image-refresh-1027.md`)
- [x] bandit-1141: update Bandit to 1.14.1 for GHSA-pxjf-g536-7r93 (HTTP/2 bodies of
      1-byte DATA frames amplify memory) (`docs/changes/bandit-1141.md`)
- [x] cloudflared-2026-10-6: update cloudflared to 2026.10.6 for the go-jose fix
      VULN-184686 (`docs/changes/cloudflared-2026-10-6.md`)
- [x] elixir-1-19-7: build the image with Elixir 1.19.7 for CVE-2026-109821
      (`URI.parse` ports) and CVE-2026-115274 (JSON integers), neither exploitable
      here; URL tests no longer assume the old port conversion
      (`docs/changes/elixir-1-19-7.md`)
- [x] mcp-serialized-tool-calls: upgrade Anubis to 2.2 so MCP sessions run
      independently, keeping the wire callers see
      (`docs/changes/mcp-serialized-tool-calls.md`)
- [x] mcp-log-redaction: keep the API key and the MCP message out of the line Anubis
      logs when a call times out or its session exits mid-call
      (`docs/changes/mcp-log-redaction.md`)
- [ ] mcp-compile-time-components: define the MCP tools and resource as compile-time
      components and drop the per-request registration. send_events still needs its
      own dispatch clause (typed validation rejects mixed batches), and the component
      DSL builds schemas differently, so compare tools/list before and after
- [ ] mcp-server-instructions: move the "what Guardian is" sentence from the query
      tool description into MCP server instructions, now that Anubis 2.x can send
      them (changes the initialize result)
- [ ] auth-failure-visibility: failed authentication is not logged or rate limited,
      and the key's length is observable through timing
- [x] fly-entry-drain: the Fly entry point kept the tunnel connector up while
      Guardian was loading or shutting down, so tunnel requests failed instead of
      going to another machine; the connector now starts once Guardian listens and
      drains before Guardian stops (`docs/changes/fly-entry-drain.md`)
- [x] system-stats-node-column: closed as already done: `system_stats` rows carry
      `host`, the machine's hostname (on Fly.io, its machine ID), which tells a
      cluster's machines apart when their hostnames differ; only the Erlang node
      name is absent
- [ ] url-port-cut: reconsider `Guardian.Query.URL`'s 20-digit port cut once every
      supported Elixir has the CVE-2026-109821 fix; dropping it loses the copy
      guarantee and changes long zero-padded ports (`docs/changes/elixir-1-19-7.md`)
- [x] release-cookie-file: no Guardian process carries the Erlang cookie on its command
      line; the VM reads it from an owner-only file written from `RELEASE_COOKIE`
      (`docs/changes/release-cookie-file.md`)

- [ ] logging: text logs cover lifecycle only and errors mean work to do; IO.puts
      moves to Logger, scrubbing stops, and a passing `mix test` prints only dots and
      the summary (`docs/changes/logging.md`)

## Tests

- [ ] test-rules: bring tests in line with CONTRIBUTING's testing philosophy a
      category at a time; the decided supervisor-tree kills are gone, and the other
      categories are pending Preston's decisions (`docs/changes/test-rules.md`)

- [x] async-default-tests: the normal `mix test` is async by default; system-table,
      suspend and peek tests go, and stop/start promises move to the excluded
      `:lifecycle` suite (`docs/changes/async-default-tests.md`)
- [ ] test-settings-as-data: tests that put query limits, the heap limit, S3
      timeouts, counter budgets or the persisted segment cache window in the
      application env, and the runtime config tests' OS environment, keep their
      modules sync; each awaits Preston's decision (`docs/changes/async-default-tests.md`)
- [x] rules-startup-lifecycle: the Rules.Server tests about startup run in the
      `:lifecycle` suite (`docs/changes/rules-startup-lifecycle.md`)
- [ ] lifecycle-whole-application: the `:lifecycle` suite stops and starts Storage on
      a peer; booting and stopping the whole application on a peer would cover clean
      shutdown end to end

- [x] persisted-segment-test-synchronization: wait for fixture creation through task
      completion instead of a 1 s message deadline; preserve segment lifetime and
      verify the retained row (`docs/changes/persisted-segment-test-synchronization.md`)

- [x] counter-test-allowance-seam-adoption: move ContextTest and CounterRuntimeTest
      allowance reads and the simulated retained charge onto the counter test budget
      helper (`docs/changes/counter-test-budgets.md`, allowance seam adoption)

- [x] counter-client-test-budget-seam: share ClientTest event construction and hide
      batch allowance storage behind the counter test budget helper
      (`docs/changes/counter-test-budgets.md`, ClientTest allowance helpers)

- [x] test-isolation: write the test-isolation pattern into CONTRIBUTING.md, drop
      redundant table deletes, make the modules that only needed unique tables async
      and state why the rest are serial (`docs/changes/test-isolation.md`)
- [x] counter-budget-options: counter budget tests that build their own Context use
      per-event options; ClientTest, ContextTest and BudgetTest go async
      (`docs/changes/counter-budget-options.md`)
- [ ] counter-budget-seam-removal: remove the application-env budget seam, `relax/1`
      and `scale/1`. End-to-end ingestion tests and peer owners have no per-call path;
      the options need a decision (`docs/changes/counter-budget-options.md`)

- [x] test-support-namespace: consolidate common helpers under `Guardian.Test.*` and
      split SQL, polling, process and segment helpers by concern without changing
      test behavior or coverage (`docs/changes/test-support-namespace.md`)

- [x] test-support-consolidation: split ExecutionTest into async round-loop and
      serial store-backed modules over a shared relaxed-store helper, fold the counter
      probes and backend into one `Guardian.Test.Counters` family, move the remaining
      cheap specialized helpers under `Guardian.Test.*`, and capture the top-N test's
      warning (`docs/changes/test-support-consolidation.md`)

- [x] rules-test-helper-follow-ups: share Rules cluster Storage-peer setup and
      successful probe compilation and cleanup
      (`docs/changes/test-infrastructure-helpers.md`)

- [x] test-infrastructure-helpers: migrate remaining scoped environment cleanup to
      `Guardian.Test.Env`, restore Rules server settings, and share single-peer query setup,
      readiness and GROUP BY partitions (`docs/changes/test-infrastructure-helpers.md`)

- [x] formatter-convergence: one `mix format` invocation handles newly wrapped
      trailing commas for explicit files and stdin without a Mix alias
      (`docs/changes/formatter-convergence.md`)
- [x] definition-block-style: use `do...end` for function and macro definitions,
      document the convention and enforce it through the normal test suite
      (`docs/changes/definition-block-style.md`)
- [x] one-module-per-file: one module or protocol per `lib/` and `libtest/` file,
      enforced by the normal test suite; `defimpl` stays with its subject
      (`docs/changes/one-module-per-file.md`)
- [x] one-alias-per-line: one alias per line, enforced by Credo's MultiAlias check
      (the only check enabled) in the pre-commit hook
      (`docs/changes/one-alias-per-line.md`)

- [x] elixir-120-compatibility: compile Guardian with warnings as errors and run the
      full suite on Elixir 1.19 and 1.20 without changing runtime pins
      (`docs/changes/elixir-120-compatibility.md`)
- [x] no-ci: remove hosted CI; the local pre-commit hook checks formatting,
      compilation, and the full suite (`docs/changes/no-ci.md`)
- [x] dev-docs-consolidate: the check commands, setup and hook installation were
      repeated in AGENTS.md, CONTRIBUTING.md, system.md and the development guide, and
      arm64 status in README.md, the single-node guide, the Dockerfile and system.md;
      the development guide and system.md 10.1 are now their one homes
- [ ] peer-start-stall: a test peer's `:peer.start` has occasionally exceeded its 15 s
      boot wait in loaded full-suite runs; cause unknown
- [x] segment-rollover-flake: SegmentTest "maximum age size rollover cancels the
      timer and ignores already delivered expiry" failed under heavy load (an append
      expected `{:ok, :full}` got `{:error, :full}`) when its 100 ms maximum age
      expired between the two appends; it now uses a maximum age it cannot reach
- [x] unit-test-work-bounds: string rendering and RowIndex CPU guards measure
      caller reductions instead of host-dependent elapsed time; other timing
      assertions are surveyed (`docs/changes/unit-test-work-bounds.md`)
- [x] unit-test-work-bounds-more: LIKE and million-digit integer CPU guards use
      calibrated caller reductions through a shared test helper; SystemStats
      timestamp freshness uses an inclusive bracket
      (`docs/changes/unit-test-work-bounds.md`, follow-up section)
- [x] counter-test-budgets: peer and ingest counter tests timed out under host load
      against cold peers and the production 50 ms call / 100 ms event budgets; peer
      tests now wait for a readiness barrier, and tests not about budgets opt in to
      larger budgets through an internal test seam (`docs/changes/counter-test-budgets.md`)
- [x] counter-test-budgets-more: ClientTest's queued-owner expiry sub-case timed out
      during its 15 ms hold under a 50 ms allowance; it and six more healthy-call
      counter tests not about budgets now relax budgets
      (`docs/changes/counter-test-budgets.md`, follow-up section)
- [x] counter-test-budgets-semantics: budget-semantics counter tests failed under load
      because 50 ms was both a reservation's size and its deadline; reservation tests
      now scale the budget and allowance together, budget-independent assertions relax,
      and duration bounds are loosened only as far as they still separate the behavior
      they guard against (`docs/changes/counter-test-budgets.md`, second follow-up)
- [x] test-env-helper: one generic test helper, `Guardian.Test.Env`, puts and restores
      `:guardian` application env on this node or on peers; four helpers that copied that
      code now delegate to it, and a fifth copy in the S3 tests was replaced by it
- [x] test-helper-follow-ups: counter result tests get budgets with a matching batch
      allowance (`Budget.healthy/2` replaces the event-level options), one polling
      helper, one unique-table helper and one peer setup replace the local copies
      (`docs/changes/test-helper-follow-ups.md`)
- [x] vm-wide-leak-tests: tests no longer count resources across the whole VM; the
      cleanup promises they guarded are tested on the specific process or file, and
      `system_stats` records open descriptors, mappings, native columns and resident
      memory to watch leaks in production (`docs/changes/vm-wide-leak-tests.md`)
- [x] async-rule-tests: rule tests that write rules, store events and run queries run
      async through the one rule server; what stays sync says why, and the rule time limit and a
      rule worker's crash have no test left (`docs/changes/async-rule-tests.md`)

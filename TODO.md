# TODO

Planned changes and known gaps. A change's design goes in `docs/changes/<id>.md`
when it needs one. This file is public: see the change-tracking rules in CLAUDE.md.

## Storage and ingestion

- [x] ingest-idempotency: optional client keys suppress matching same-node batch
      retries with short-lived, bounded in-memory receipts; availability first
      (`docs/changes/ingest-idempotency.md`)
- [ ] ingest-idempotency-cluster: route keyed ingests to an owner so retries through
      different nodes can share receipts; define membership/failure behavior
- [ ] harden-shutdown-persist: a segment whose pack raises during shutdown (an
      unexpected reply such as `{:error, :not_frozen}` fails a match) aborts persistence
      of every remaining full segment
- [ ] segment-count-columns: segment files still carry six per-type count columns
      (null, false, true, int, float, string) that nothing reads; dropping them changes
      the format, so it needs a format version and a migration plan
- [ ] serialize-segment-deletion: deleting a segment while it is being persisted, or
      after its file is written but before LoadedSegments registers it, leaves a file
      the next rescan loads again
- [ ] segment-schema-gaps: the schema (SHOW TABLES, DESC, the schema table, SELECT *)
      misses segments that are full or persisted but not yet loaded, and a segment
      that dies between LoadedSegments starting it and Guardian.Storage.Schema registering it
      crashes them (docs/architecture/system.md 4.2 and 4.5)
- [ ] reject-oversized-events: reject, never partly store, an event whose flattened
      row has more than 1,000 columns or 1,000,000 slots, reporting it as that event's
      failed result
- [ ] segment-slot-and-column-caps: cap a mutable segment's columns and slot area
      before each append, beside today's row and byte caps
- [x] ingest-rules: SET and UNSET rules stored as files (`<table>/<name>.gsql`, in a
      folder or an S3-compatible bucket), run on API ingests before storage, managed
      through MCP tools with whole-set validation and a store-held write lock
      (`docs/changes/ingest-rules.md`)
- [ ] rules-rollout: put rules into the maintainer's deployment (`fly.toml`), each
      step only on the maintainer's go, and each after the one before is checked
      1. Deploy done (2026-10-24, `c5df444`): no `GUARDIAN_RULES_*` settings or
         secrets, empty local `/data/rules`, and no rules written. The `:re` hold
         cleared: erlang/otp#10432 affects OTP 28.0–28.2 and is fixed from 28.3;
         the deployed image uses OTP 28.5.0.8. Checked `/health`, MCP `list_rules`
         returning empty, live ingestion and queries, and canonical UTC `date_add`
         succeeding (numeric offsets return null). The boot line was outside Fly's
         latest-100-log buffer; direct runtime checks confirmed the empty local
         folder, empty rule list and absence of rule settings instead.
      2. Bucket: an R2 bucket and a bucket-scoped object read/write token, made by
         the maintainer; the secret goes straight into the deployment's secrets,
         never printed or stored here. Check the credentials from the deployment's
         own network as `docs/guides/rules.md` ("Switching an existing deployment to
         a bucket") describes, conditional writes included (a second
         `If-None-Match: *` create gets 412).
      3. Switch: stage every `GUARDIAN_RULES_S3_*` setting (bucket, `https://`
         endpoint, key ID and secret, plus a prefix if used) and apply them in one
         restart.
         Copy any rules from `/data/rules` into the bucket first. Checks: the boot log
         names the bucket, `list_rules` shows the copied rules, and a test write and
         delete through the MCP tools succeed. Rollback: remove them all together,
         in one restart (removing some refuses startup); `/data/rules` stays.
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
- [x] counter-retirement: remove legacy scalar cluster entry points and the
      counter aggregate adapter; carry resolved shared aggregate configurations
      through rule plans and batched execution (`docs/changes/counter-retirement.md`)
- [x] counter-client: split the batched Client facade from Transport and Budget,
      preserving counter behavior (`docs/changes/counter-client.md`)
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
- [ ] engine-single-flatten: Engine flattens each ingested event twice (store, then
      check the returned event); skip the check for events without atom keys
- [ ] fix-unflatten-nil-list-items: unflattening a list holding nil beside a list of
      objects (`[null, [{"a": 1}]]`) raises `FunctionClauseError` (Engine rescues it)
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

## Queries

- [x] timestamp-offsets: time arithmetic and epoch conversion accept only UTC
      `YYYY-MM-DD HH:MM:SS`; numeric offsets and other formats give null
      (`docs/changes/timestamp-offsets.md`)
- [ ] timestamp-arithmetic-helper: consolidate date_add/date_sub's duplicated
      bounds and arithmetic with shared timestamp-to-seconds validation, avoiding
      double parsing and exception-based invalid-input handling (code review follow-up)
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
- [ ] query-memory-bound: result sizes, string sizes, run time and each query
      process's heap are bounded, but a query's total memory is not (GROUP BY state in
      ETS, column data in native memory, many processes); a deliberate or exotic query
      can still exhaust a machine and lose its unpersisted events
- [ ] list-field-paths: let `users.name` find the list column `users..name`
- [ ] statement-node-set: compute a statement's node set once, so a hung peer's 5 s
      readiness check is paid once per query and resolve and FROM see the same nodes
- [ ] json-query-error-responses: JSON `/query` returns a bare 500 for parse and
      resolve errors, where MCP reports the message; return 400 with `info`
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
      module's entry points (`lib/guardian/query/function/CLAUDE.md`)
- [ ] test-only-labels: `Guardian.Query.labels/1` (SQL text) and the SHOW/DESC clauses of
      `Guardian.Query.Resolver.labels/1` are reached only from tests, since the Resolver
      rewrites SHOW and DESC first; drop them and test SHOW/DESC labels through
      `Guardian.Query.Resolver.resolve/1`

## Interfaces and operations

- [x] nested-agent-instructions: expose every nested CLAUDE.md through a relative
      AGENTS.md symlink and require reading all applicable ancestor instructions
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
- [ ] mcp-serialized-tool-calls: Anubis 0.16 runs tool calls in its one server
      process, so a slow MCP query blocks every MCP session for up to the 30 s query
      time limit. Options: answer `query` calls in `Guardian.Web.MCP.Router` before Anubis, or
      migrate to Anubis 2.x and recheck
- [ ] mcp-compile-time-components: during the Anubis 2.x migration, define the MCP
      tools and resource as compile-time components and drop the per-request
      registration and the `Handlers.handle/3` call
- [ ] mcp-server-instructions: after an Anubis upgrade past 0.16, move the "what
      Guardian is" sentence from the query tool description into MCP server
      instructions (0.16 cannot send them)
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

## Tests

- [x] definition-block-style: use `do...end` for function and macro definitions,
      document the convention and enforce it through the normal test suite
      (`docs/changes/definition-block-style.md`)

- [x] elixir-120-compatibility: compile Guardian with warnings as errors and run the
      full suite on Elixir 1.19 and 1.20 without changing runtime pins
      (`docs/changes/elixir-120-compatibility.md`)
- [x] no-ci: remove hosted CI; the local pre-commit hook checks formatting,
      compilation, and the full suite (`docs/changes/no-ci.md`)
- [x] dev-docs-consolidate: the check commands, setup and hook installation were
      repeated in CLAUDE.md, CONTRIBUTING.md, system.md and the development guide, and
      arm64 status in README.md, the single-node guide, the Dockerfile and system.md;
      the development guide and system.md 10.1 are now their one homes
- [ ] peer-start-stall: a test peer's `:peer.start` has occasionally exceeded its 15 s
      boot wait in loaded full-suite runs; cause unknown
- [x] segment-rollover-flake: SegmentTest "maximum age size rollover cancels the
      timer and ignores already delivered expiry" failed under heavy load (an append
      expected `{:ok, :full}` got `{:error, :full}`) when its 100 ms maximum age
      expired between the two appends; it now uses a maximum age it cannot reach

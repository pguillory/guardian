# TODO

Planned changes and known gaps. A change's design goes in `docs/changes/<id>.md`
when it needs one. This file is public: see the change-tracking rules in CLAUDE.md.

## Storage and ingestion

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
      that dies between LoadedSegments starting it and Storage.Schema registering it
      crashes them (docs/architecture/system.md 4.2 and 4.5)
- [ ] reject-oversized-events: reject, never partly store, an event whose flattened
      row has more than 1,000 columns or 1,000,000 slots, reporting it as that event's
      failed result
- [ ] segment-slot-and-column-caps: cap a mutable segment's columns and slot area
      before each append, beside today's row and byte caps
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
      bytes; lift it once key and schema memory is bounded (check `Cluster.Metadata`)
- [ ] column-nif-dirty-schedulers: `to_list`, `filter`, and packing over 64 MiB
      columns run for tens of milliseconds on normal schedulers
- [ ] validate-packed-columns: unpacking a corrupt segment file aborts the VM through
      asserts instead of returning an error
- [ ] sweep-stale-temp-segments: a crash between writing and renaming a segment leaves
      its `{final}.{n}.tmp` file in the segment directory forever (ignored by the
      loader); remove stale temp files at startup

## Queries

- [x] regex-on-re-drop-jq: `replace()` with growing or overlapping matches aborted the
      VM in the Hyperscan NIF; regular expressions now run on `:re` with backtracking
      limits, and jq() and the Hyperscan and libjq dependencies are gone
      (`docs/changes/regex-on-re-drop-jq.md`)
- [x] query-log: every JSON and MCP query is recorded in the built-in `queries`
      table, once on the coordinating machine (`docs/changes/query-log.md`)
- [ ] drop-query-parse-errors: `queries` records every parse failure too (with
      `error_kind = 'parse'`, without the hourly cap); drop `query_parse_errors` and
      its recorder, moving `truncate/2` to `Utils` and the caller helpers to a small
      `Web.Caller` module
- [x] replace-offset-memory: `replace` held every match offset of a value with no
      bound when `GUARDIAN_QUERY_MAX_HEAP_MB=0`; a value over 16 KiB is now replaced in
      a helper process with its own heap cap (`docs/changes/replace-offset-memory.md`)
- [ ] ci-arm64-image: CI builds only the amd64 image; build linux/arm64 too, which
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
- [ ] interval-round-trip: `INTERVAL 2 WEEK` unparses to `interval('2w')`, which does
      not parse (INTERVAL is a keyword), so its column label cannot be re-parsed
- [ ] test-only-labels: `Query.labels/1` (SQL text) and the SHOW/DESC clauses of
      `Query.Resolver.labels/1` are reached only from tests, since the Resolver
      rewrites SHOW and DESC first; drop them and test SHOW/DESC labels through
      `Query.Resolver.resolve/1`

## Interfaces and operations

- [ ] mcp-serialized-tool-calls: Anubis 0.16 runs tool calls in its one server
      process, so a slow MCP query blocks every MCP session for up to the 30 s query
      time limit. Options: answer `query` calls in `Web.MCP.Router` before Anubis, or
      migrate to Anubis 2.x and recheck
- [ ] mcp-compile-time-components: during the Anubis 2.x migration, define the MCP
      tools and resource as compile-time components and drop the per-request
      registration and the `Handlers.handle/3` call
- [ ] mcp-server-instructions: after an Anubis upgrade past 0.16, move the "what
      Guardian is" sentence from the query tool description into MCP server
      instructions (0.16 cannot send them)
- [ ] auth-failure-visibility: failed authentication is not logged or rate limited,
      and the key's length is observable through timing
- [ ] system-stats-node-column: `system_stats` rows carry no node identity, so a
      cluster's metrics can't be told apart by machine

## Tests

- [ ] peer-start-stall: a test peer's `:peer.start` has occasionally exceeded its 15 s
      boot wait in loaded full-suite runs; cause unknown
- [ ] segment-rollover-flake: SegmentTest "maximum age size rollover cancels the
      timer and ignores already delivered expiry" failed once under heavy load (an
      append expected `{:ok, :full}` got `{:error, :full}`); possibly the 100 ms
      maximum age expiring between the two appends

# Async by default: the normal `mix test`

Status: done.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Tests, test support, CONTRIBUTING.md, the guides and
architecture docs, plus two behavior-neutral signature changes outside tests:
`Guardian.Cluster.discovery_child_spec/2` takes the DNS query as an argument (default:
the configured `:dns_cluster_query`) and the release step
`Guardian.MixProject.require_prod_release/2` takes the Mix env (default: `Mix.env()`).

## Problem

Fifty-one test modules ran `async: false`, many for reasons that no longer held or
never did. Measured at default concurrency, sync modules took 49 s of a 119 s run, and
seven modules (segment_reader_contract alone 19 s) held most of that.
Preston's direction: the normal run is async by default, and a module is sync only
when it truly can't be made async.

## Decisions

1. CONTRIBUTING.md says it: async by default, and a sync module names its one reason.
   The allowed reasons are the OS environment, a connected peer, the `:lifecycle`
   suite's stops, node-wide counter budgets, the rule server's store and published map, log capture that
   must see only its own events, and an application env setting the code reads instead
   of taking as an argument (being retired). Suspending, restarting or scanning application processes is
   not a reason: those tests go.
2. The built-in tables `queries`, `query_parse_errors`, `web_requests` and
   `web_responses` are for ad hoc analysis. Tests don't check their contents or that
   writes happen. Ingest idempotency is the IngestIdempotency coordinator, not those
   tables, and stays tested at the API level.
3. MCP sessions are independent (Anubis 2.x), so MCP tests run async. Each
   `Guardian.Test.MCPClient.start/0` gets its own client, Finch pool and client name
   (Anubis names a private ETS table after the client name).
4. Promises that need a server to stop and start are tagged `:lifecycle`, a slow
   synchronous suite excluded by default. Today that is a Storage stop and restart on a
   peer and a call of the stop callback, not a whole-application boot. Pre-flight before every deploy:
   `mix test --include cluster --include lifecycle`.

## What moved

To `:lifecycle` (`test/guardian/lifecycle_test.exs`):

- A stopping machine refuses new queries and tells peers it isn't ready (was
  `application_test.exs`). It calls the stop callback and flips the VM-wide flag; it does
  not truly stop the server.
- New: acknowledged rows still in a mutable segment survive a Storage stop and restart.
  A peer VM runs Storage, stops it through its supervisor
  (`Guardian.Test.Cluster.stop_storage/1`), halts, and a new peer on the same data reads
  the rows back. This is a Storage stop and start, not a whole-application one.

To small sync modules, each with its reason:

- `web/json_api_log_test.exs` (log capture): the forced 500 that must not log the API
  key, and the two real-listener body tests. The forced 500 causes a crash on purpose,
  which the logging rules don't allow; it is a security check, held for Preston.
- `web/auth_settings_test.exs` (application env): an unset ingest key matches nothing,
  and the removed `GUARDIAN_API_KEY` setting grants nothing (unit and through the
  routers).
- `storage/persisted_segments_settings_test.exs` (application env): an invalid
  `persisted_segment_cache_ms` stops the persister from starting.

## What went, and the promise each guarded

These now go to an agent's hand check when a change touches segment lifetimes or
persistence (insert, stop, start, query, and the specific race below):

1. Never partial, and reads under slow or vanishing segments
   (`query/pipeline_failures_test`, `query/segment_reader_contract_test`): a killed
   query worker fails the query instead of dropping rows; a LIMIT returns while workers
   still run; a segment slow past 5 s is still read in full; a segment deleted mid-query
   fails the query naming it; Storage's own reads give up on a hung segment after 5 s;
   pack exits for the persister when a segment dies after freezing; a segment that is
   gone, or dies mid-call, returns `segment_unavailable`; a slow segment is waited for
   unless the caller gives a timeout; a read is retried once, only after a normal stop
   and only on another copy; the caller's mailbox and monitors stay clean after a
   timed-out query.
2. Query time limit enforcement on one node: a query past its limit is stopped and the
   caller left clean; a result racing the limit never stays in the mailbox. The
   `:cluster` test of the limit on every machine stays.
3. Handoff races (`storage/handoff_visibility_test`, whole file): snapshots and lookups
   follow mutable → full → persisted → loaded handoffs at every read boundary; cache
   expiry before a disk scan keeps rows; a delayed Loaded manager can't evict a cache
   entry early; stale expiry doesn't reload a removed entry or recreate a deleted file;
   expiry rewrites an unreadable file from memory, or keeps serving if it can't.
4. Retirement (`storage/persisted_segment_retirement_test`): the in-memory copy stops
   once its file is loaded, when the cache window loads it, or when its file is deleted,
   and keeps running when an unreadable file can't be repaired; a read racing the stop
   is retried once on the file; a snapshot from the in-memory copy reads the same rows
   from the saved copy (the snapshot row-count cut, `lib/guardian/storage/AGENTS.md`);
   the configured cache window ends with the copy stopped.
5. Persistence scheduling (`storage/persisted_segments_scheduling_test`, whole file):
   one recurring timer whatever the pings; pings persist pending segments before a
   barrier; periodic persistence picks up new work across ticks.
6. Mutable segment maximum age (`storage/mutable_segments_test`): quiet partial
   segments hand off and persist; empty segments stay mutable until their first write.
7. Segment owner exits (`storage/segment_owner_exits_test`): a schema lookup on a
   segment that doesn't answer fails by kind; deleting a table stops a segment held in
   FullSegments (the unpersistable fixture could log persist errors under concurrency).
   Deleting a table still stops its mutable and persisted segments.
8. MCP cancellation (`web/mcp/cancellation_test`, whole file): a cancelled or deleted
   request stops a running query; a cancelled send_events still stores its whole batch.
   Both need the request held inside Guardian to observe.
9. MCP session expiry through Anubis's idle timer (two tests). DELETE still covers a
   lost session and re-initializing.
10. The built-in tables: `web/query_log_test`, `web/query_parse_errors_test`,
    `web/logger_test`, `cluster/query_log_test` (whole files), json_api's "web_requests
    records which key", and client_test's "request logs are queryable". Their capture_log
    uses, including the hourly parse-error drop line, went with them. Kept: failures
    from the query path reach the caller unchanged (`web/query_test`). Also gone with
    those files: a failing caller-info function doesn't change the query's answer; a
    stalled recorder never delays a query; `record` never raises; recorder failures log
    only their kind, never query text (a security promise, security.md, like the held
    forced-500 test); the built-in tables exist and answer DESC and SHOW TABLES.

Rewritten rather than deleted: the MCP key drop (`web/mcp/key_drop_test`) checks the
whole conn the router hands Anubis, and `Guardian.Web.Auth.drop_api_key/1`, instead of
reading Anubis session state.

Kept as a judgment call: `web/ingest_retry_test` and `web/mcp/client_test` create an
in-flight idempotency claim by calling the IngestIdempotency coordinator directly,
since an API request can't hold one open without timing. Each uses its own table.

## Not decided here

Settings that tests change through the application env, listed for Preston in the
builder's report: query result limits, the query heap limit, S3 timeouts,
`config/runtime.exs` (OS environment), counter budgets, the persisted segment cache
window.

## Timings

Before (cd68c7e, default concurrency, loaded machine): 119.0 s (70.0 s async, 49.0 s
sync), 1269 tests.

After, three runs at default concurrency on a shared machine (load varied): 62.9 s
(38.9 s async, 23.9 s sync), 66.3 s (35.8, 30.4) and 74.8 s (56.0, 18.8), 1187 tests.
Most of the sync time left is the rule tests (another change) and the heap and regex
memory tests, which wait on the settings decisions.

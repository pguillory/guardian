# Guardian Source Code

The `lib/guardian/` directory contains the event store, query engine, and network interfaces.

## Top-level modules

Every Guardian-owned module and protocol belongs under `Guardian.*`, including
`Guardian.Web.*`. External protocol implementations retain the external protocol's
prefix. Keep the Mix application and its configuration under `:guardian`.

- `Guardian.Application`: starts Guardian.Rules.Server (first, so a bad rule store fails
  startup fast), Guardian.Counters.Restarter, Guardian.Storage,
  Guardian.SystemStats, Guardian.Web.QueryParseErrors, Guardian.Web.QueryLog,
  Guardian.Web.IngestIdempotency, Guardian.Web, and DNS peer discovery (only when
  `DNS_CLUSTER_QUERY` is set; on Fly.io it defaults to `<app>.internal`).
- `Guardian.Web.IngestIdempotency`: bounded node-local client-key receipts, started before
  Guardian.Web. It holds only metadata and never runs ingestion; unavailability fails open.
- `Guardian.Engine`: validates and ingests events, running the table's rules on API ingests.
- `Guardian.Rules`: ingest-time SET/UNSET/TRACK/LOOKUP rules stored as files (`lib/guardian/rules/CLAUDE.md`).
- `Guardian.Counters.Store`: node-local, ephemeral ETS get/gets/cas/incr store with TTLs and
  a memory budget (`lib/guardian/counters/CLAUDE.md`); TRACK/LOOKUP run through Rules using
  bounded owner routing and fail-open defaults.
- `Guardian.Counters.Restarter`: owns the disposable Store/Cluster supervisor and recovers
  it with backoff, so counter crash loops cannot exhaust Guardian.Application's restart intensity.
- `Guardian.Storage`: custom columnar segment storage.
- `Guardian.Query`: plans and executes SQL-like queries. `Guardian.Query.Limits` holds the per-query
  bounds, including the per-process heap limit (`GUARDIAN_QUERY_MAX_HEAP_MB`) on the
  query process and its pipeline workers (`lib/guardian/query/CLAUDE.md`).
- `Guardian.AST`: parses and traverses query syntax.
- `Guardian.Aggregation`: query-time aggregation registry, and the functions that run an
  aggregation (`default`, `start`, `start_row`, `merge`, `finish`).
- `Guardian.Web`: JSON and MCP servers.
- `Guardian.Cluster`: distributed query coordination and the DNS discovery child.
  `Guardian.Cluster.Metadata` fans schema lookups out to every connected node and merges the
  results.
- `Guardian.SystemStats`: the runtime child that records VM metrics (below).
- Leaf helpers (`Guardian.Build`, `Guardian.SegmentID`, `Guardian.SortedSet`,
  `Guardian.Timestamp`, `Guardian.Utils`) live directly in this directory; their rules
  are in "Leaf utilities" below.

Node naming has three modes, set in `rel/env.sh.eex`: on Fly.io (`FLY_PRIVATE_IP`),
`guardian@<private IPv6>`; elsewhere with `GUARDIAN_NODE_HOST`, `guardian@<that
address>` (IPv6 distribution when it contains `:`); otherwise a single node,
`guardian@localhost` with epmd and distribution on loopback only. The first two need
`RELEASE_COOKIE`. With `DNS_CLUSTER_QUERY` set, `Guardian.Cluster.discovery_child_spec/1`
refuses at boot a node whose host is not a non-loopback IP written as `:inet.ntoa/1`
writes it, and queries AAAA or A records to match. Every node in a cluster must run the
same build: mid rolling deploy, queries can fail until all nodes are upgraded.

Rules run on the ingestion path, but only compiled rule sets loaded in memory; the
rule store (a folder or an S3 bucket) is read at startup, on reload and by a poll,
never per event. Guardian has no external metadata/runtime services. Do not add
external calls to the ingestion path.

Guardian is single-user. Storage and query operations are scoped by table only;
persisted segment files are named `{table}.{segment_id}.seg`.

`Guardian.SystemStats` is a required runtime child. It writes Erlang VM metrics to the
`system_stats` stream through `Guardian.Engine.try_log_event/2` every second, each event with a
`Guardian.Timestamp.now/0` timestamp. Its `counters_available` field reports counter process
presence without waiting for counters. Keep it free of external services.

Read the nearest subsystem CLAUDE.md before editing and run the full suite afterward.

## Leaf utilities

Utilities are leaf helpers: build information (`Guardian.Build`), segment IDs
(`Guardian.SegmentID`), `Guardian.SortedSet`, timestamps (`Guardian.Timestamp`), and
`Guardian.Utils` (hostname, ETS streaming). They call no other Guardian subsystem
(Engine, Storage, Query, AST, Web, Cluster); keep it that way, and put a helper with
a single user next to that user instead.

- `Guardian.SegmentID` creates sortable 32-byte hex identifiers containing a timestamp.
- `Guardian.Timestamp.now/0` is UTC, formatted `YYYY-MM-DD HH:MM:SS`.
  `Guardian.Timestamp.from_string/1` and `to_seconds/1` accept only that exact UTC
  format: no `T`, `Z`, fractional seconds or numeric offsets. They validate calendar
  fields and years 0000 to 9999.

Utility changes should include focused unit tests.

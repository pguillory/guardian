# Guardian Source Code

The `lib/` directory contains the event store, query engine, and network interfaces.

## Top-level modules

- `Main`: starts Storage, SystemStats, Web.QueryParseErrors, Web, and
  DNS peer discovery (only when `DNS_CLUSTER_QUERY` is set; on Fly.io it defaults to
  `<app>.internal`).
- `Engine`: validates and ingests events.
- `Storage`: custom columnar segment storage.
- `Query`: plans and executes SQL-like queries. `Query.Limits` holds the per-query
  bounds, including the per-process heap limit (`GUARDIAN_QUERY_MAX_HEAP_MB`) on the
  query process and its pipeline workers (`lib/query/CLAUDE.md`).
- `AST`: parses and traverses query syntax.
- `Aggregation`: query-time aggregation registry, and the functions that run an
  aggregation (`default`, `start`, `start_row`, `merge`, `finish`).
- `Web`: JSON and MCP servers.
- `Cluster`: distributed query coordination and the DNS discovery child.
  `Cluster.Metadata` fans schema lookups out to every connected node and merges the
  results.
- `SystemStats`: the runtime child that records VM metrics (below).
- `Console`: the operator's remote-shell tool; `Console.query/1` prints a query's
  rows as a table.
- `lib/utils`: leaf helpers (`Build`, `SegmentID`, `SortedSet`, `Timestamp`, `Utils`)
  that call no other subsystem.

Node naming has three modes, set in `rel/env.sh.eex`: on Fly.io (`FLY_PRIVATE_IP`),
`guardian@<private IPv6>`; elsewhere with `GUARDIAN_NODE_HOST`, `guardian@<that
address>` (IPv6 distribution when it contains `:`); otherwise a single node,
`guardian@localhost` with epmd and distribution on loopback only. The first two need
`RELEASE_COOKIE`. With `DNS_CLUSTER_QUERY` set, `Cluster.discovery_child_spec/1`
refuses at boot a node whose host is not a non-loopback IP written as `:inet.ntoa/1`
writes it, and queries AAAA or A records to match. Every node in a cluster must run the
same build: mid rolling deploy, queries can fail until all nodes are upgraded.

Guardian does not have a rule execution layer or external metadata/runtime services.
Do not add external calls to the ingestion path.

Guardian is single-user. Storage and query operations are scoped by table only;
persisted segment files are named `{table}.{segment_id}.seg`.

`SystemStats` is a required runtime child. It writes Erlang VM metrics to the
`system_stats` stream through `Engine.try_log_event/2` every second, each event with a
`Timestamp.now/0` timestamp. Keep it free of external services.

Read the nearest subsystem CLAUDE.md before editing and run the full suite afterward.

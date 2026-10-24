# Guardian - AI Assistant Context

## Meta-Instructions

"Remember": When the user says "remember [something]", save it in this file in the
appropriate section.

Markdown style: Do not use `**` to highlight list items. Write `1. First thing: text`
instead.

Every directory in `lib/` may have a CLAUDE.md with subsystem-specific guidance. Read
the applicable file before editing that subsystem.

## Change Tracking

Guardian tracks planned work in TODO.md and details changes in `docs/changes/`.
Both are public, like everything in this repository: never put secrets, credentials,
private infrastructure details (hostnames, account IDs, machine IDs), personal data,
or the internals of other projects in them, or anywhere else in the tree. Notes about
a particular deployment belong with that deployment, not here.

- Read the applicable change document before implementation.
- State each change document's expected product spec impact before implementation:
  which statements in `docs/product/overview.md` or `docs/product/spec.md` change or
  get added, or "none".
- Update TODO.md and the change document when work completes.
- Record conceptually distinct follow-up work instead of expanding the current change.

## Product

Guardian is a single-tenant, self-hosted, schemaless event store with a SQL-like query
engine, licensed MIT. It ingests JSON events into a custom columnar format and supports
interactive analysis through JSON and MCP interfaces. It runs as one node or as a
cluster (DNS discovery on any machines, with Fly.io as a preset).

Product docs, in tiers that each extend the one above: the one-sentence, one-paragraph,
and one-page descriptions in `docs/product/overview.md`, and the full product spec in
`docs/product/spec.md`. Read them before changing user-visible behavior, and update
them when that behavior changes. How the system is built (supervision tree, ingest,
storage, queries, interfaces, clustering, configuration, deployment, testing) is in
`docs/architecture/system.md`; read it before structural changes and update it when a
structure it describes changes. ARCHITECTURE.md is an index of these docs, and the
subsystem CLAUDE.md files hold the rules for editing each subsystem. The security
design (trust boundaries, invariants, known gaps) is in
`docs/architecture/security.md`; read it before changing authentication, the HTTP or
MCP routers, query functions, logging, secrets, or the Fly deployment, and update it
when those change.

Rules are files of SET and UNSET statements per table (`<table>/<name>.gsql`), run on
each ingested event before storage (`lib/rules/CLAUDE.md`, `docs/changes/ingest-rules.md`).
They have no state and make no external calls; TRACK and LOOKUP counters are designed
for but not built. There is no PostgreSQL metadata store, Memcached runtime, or MaxMind
service. Guardian is single-user: authentication is one environment-configured API key
(at least 32 bytes, in the `x-api-key` header; the `api_key` query parameter only with
`GUARDIAN_ALLOW_QUERY_API_KEY=true`), and a valid key grants access to the whole event
store. There is no user namespace.

## Design Principles

- Keep the ingestion path predictable and free of external service calls.
- Treat Storage as the source of truth for event data and inferred schemas.
- Preserve query-time aggregations and scalar query functions.
- Run the full test suite after every change.
- Preserve the `SystemStats` process and its `system_stats` event stream.

## Architecture

Summary; the full description is `docs/architecture/system.md`.

The runtime consists of Rules.Server (loads the rule store first; an unreachable or
misconfigured store refuses startup), Storage, SystemStats, Web.QueryParseErrors (records query
parse failures), Web.QueryLog (records every API query in `queries`), Web, and
Cluster (DNS peer discovery
through `DNS_CLUSTER_QUERY`; `<app>.internal` by default on Fly.io). Schema lookups (SHOW TABLES, DESC, the `schema` virtual table, SELECT *) fan
out to every connected node through `Cluster.Metadata`.

Event ingestion:

```text
Engine.ingest_events(table, events)
  -> validate storage-safe values
  -> the table's rules (Rules.Runner, in a worker), then validate their outputs
  -> Storage.append(table, event)
```

Query execution:

```text
SQL -> AST -> Query.Resolver -> Query.Planner -> Query.Evaluation -> rows
```

Storage uses mutable, full, persisted, and loaded segment managers. Files are named
`{table}.{segment_id}.seg`.

Authentication reads only `GUARDIAN_API_KEY`, which may rotate freely.

Node naming (`rel/env.sh.eex`) has three modes: Fly.io (`FLY_PRIVATE_IP`), a cluster
member elsewhere (`GUARDIAN_NODE_HOST`), and a single node (`guardian@localhost`, with
distribution on loopback only). Clustered modes need `RELEASE_COOKIE`; peers are found
through `DNS_CLUSTER_QUERY` (on Fly, `<app>.internal` by default). Keep Fly's output of
`rel/env.sh.eex` unchanged unless the change is meant for Fly: `test/deployment_test.exs`
pins it.

Fly.io is the best-supported deploy path (`Dockerfile`, `fly.toml`, `docs/guides/fly.md`).
The `fly.toml` in the tree is the maintainer's own deployment, including a marked block
of overrides (`GUARDIAN_ALLOW_QUERY_API_KEY`, `GUARDIAN_QUERY_MAX_HEAP_MB`) that a test
keeps active; don't drop them without the maintainer's say-so. `GUARDIAN_API_KEY` and
`RELEASE_COOKIE` are Fly secrets, plus the optional `TUNNEL_TOKEN` that starts the
Cloudflare Tunnel connector (`bin/fly-start`, the image's entry point); segments live on
a per-machine volume at `GUARDIAN_DATA_DIR=/data`. Keep Fly's `kill_timeout` above
Storage's shutdown budget plus the connector's drain (20 s at worst). The rest of
`bin/` is development tooling (`pre-commit`, `install-git-hooks`). `examples/docker-compose.yml` is an unverified three-node example.

## Development

```sh
mix format
MIX_ENV=test mix compile --warnings-as-errors
mix test --warnings-as-errors
```

Tests must not require PostgreSQL, Memcached, GeoIP files, or other external services.
No CI: never add GitHub Actions or other hosted CI; tests run locally at commit time.
The pre-commit hook checks staged whitespace, formatting, compilation, and the full
test suite. See `docs/guides/development.md` for hook setup.

Key subsystem documentation:

- `lib/storage/CLAUDE.md`
- `lib/query/CLAUDE.md`
- `lib/query/function/CLAUDE.md`
- `lib/aggregation/CLAUDE.md`
- `lib/ast/CLAUDE.md`
- `lib/web/CLAUDE.md`
- `lib/rules/CLAUDE.md`

Last updated: 2026-10-23

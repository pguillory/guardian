# Guardian - AI Assistant Context

## Meta-Instructions

"Remember": When the user says "remember [something]", save it in this file in the
appropriate section.

Markdown style: Do not use `**` to highlight list items. Write `1. First thing: text`
instead.

Guardian modules live under `lib/guardian/`. Before editing any file under `lib/`,
read every existing CLAUDE.md from `lib/` down to the file's directory (for example,
`lib/CLAUDE.md` if present, `lib/guardian/CLAUDE.md`, and
`lib/guardian/query/CLAUDE.md`). Nested
AGENTS.md files are relative symlinks to the canonical CLAUDE.md beside them.

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

Rules are files of SET, UNSET, TRACK and LOOKUP statements per table (`<table>/<name>.gsql`), run on
each ingested event before storage (`lib/guardian/rules/CLAUDE.md`, `docs/changes/ingest-rules.md`).
SET/UNSET are stateless. TRACK/LOOKUP use ephemeral counters on Guardian nodes,
bounded peer calls and aggregate defaults on failure; final UNSETs still run.
Counters are advisory, lose state on restart/eviction/cluster changes and use private
arrival metadata, never caller timestamps. There is no PostgreSQL metadata store, Memcached
runtime, or MaxMind service. Guardian is single-user: authentication is one environment-configured API key
(at least 32 bytes, in the `x-api-key` header; the `api_key` query parameter only with
`GUARDIAN_ALLOW_QUERY_API_KEY=true`), and a valid key grants access to the whole event
store. There is no user namespace.

## Design Principles

- Keep the ingestion path predictable and free of external service calls.
- Treat Storage as the source of truth for event data and inferred schemas.
- Preserve query-time aggregations and scalar query functions.
- Run the full test suite after every change.
- Preserve the `Guardian.SystemStats` process and its `system_stats` event stream.

## Architecture

All Guardian-owned modules use `Guardian.*`, including `Guardian.Web.*`; do not add
unprefixed modules. The Mix application/configuration namespace remains `:guardian`.
The namespace transition requires a full release restart, with no disk migration
(`docs/changes/guardian-namespace.md`).

Source paths follow module names under `lib/guardian/`; tests mirror their subjects
under `test/guardian/`, and compiled test helpers follow module names under
`libtest/guardian/`. Each `lib/` and `libtest/` file defines one module
(CONTRIBUTING.md). Keep the shared test bootstrap and fixtures at
`test/test_helper.exs` and `test/fixtures/`.

Summary; the full description is `docs/architecture/system.md`.

The runtime consists of Guardian.Rules.Server (loads the rule store first; an
unreachable or misconfigured store refuses startup), Guardian.Counters.Restarter
(isolates and recovers Guardian.Counters.Supervisor, with node-local
Guardian.Counters.Store and Guardian.Counters.Budget behind the bounded
Guardian.Counters.Client facade for TRACK/LOOKUP), Guardian.Storage, Guardian.SystemStats,
Guardian.Web.QueryParseErrors (records query parse failures), Guardian.Web.QueryLog
(records every API query in `queries`), Guardian.Web.IngestIdempotency (short-lived,
node-local client-key receipts), Guardian.Web, and Guardian.Cluster (DNS discovery
through `DNS_CLUSTER_QUERY`; `<app>.internal` by default on Fly.io). Schema lookups
(SHOW TABLES, DESC, the `schema` virtual table, SELECT *) fan out to every connected
node through `Guardian.Cluster.Metadata`.

Event ingestion:

```text
Guardian.Engine.ingest_events(table, events)
  -> validate storage-safe values
  -> the table's rules (Guardian.Rules.Runner, in a worker), then validate their outputs
  -> Guardian.Storage.append(table, event)
```

Query execution:

```text
SQL -> Guardian.AST -> Guardian.Query.Resolver -> Guardian.Query.Planner
  -> Guardian.Query.Evaluation -> rows
```

Storage uses mutable, full, persisted, and loaded segment managers. Files are named
`{table}.{segment_id}.seg`.

Authentication reads only `GUARDIAN_API_KEY`, which may rotate freely.

Node naming (`rel/env.sh.eex`) has three modes: Fly.io (`FLY_PRIVATE_IP`), a cluster
member elsewhere (`GUARDIAN_NODE_HOST`), and a single node (`guardian@localhost`, with
distribution on loopback only). Clustered modes need `RELEASE_COOKIE`; peers are found
through `DNS_CLUSTER_QUERY` (on Fly, `<app>.internal` by default). Keep Fly's output of
`rel/env.sh.eex` unchanged unless the change is meant for Fly: `test/guardian/deployment_test.exs`
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

Local Homebrew uses Elixir 1.19.3 with `erlang@28` (OTP 28.5.0.8).
[`docs/guides/development.md`](docs/guides/development.md) is the one home for the
toolchain (including the OTP 28.2 crash fix), setup, hook installation and the
checks: read it before running or changing them. Run `mix format` first; the
pre-commit hook runs the checks the guide lists.

Tests must not require PostgreSQL, Memcached, GeoIP files, or other external services.
No CI: never add GitHub Actions or other hosted CI; tests run locally at commit time.

Key subsystem documentation:

- `lib/guardian/storage/CLAUDE.md`
- `lib/guardian/query/CLAUDE.md`
- `lib/guardian/query/function/CLAUDE.md`
- `lib/guardian/aggregation/CLAUDE.md`
- `lib/guardian/ast/CLAUDE.md`
- `lib/guardian/web/CLAUDE.md`
- `lib/guardian/rules/CLAUDE.md`
- `lib/guardian/counters/CLAUDE.md`
- `lib/guardian/object_store/CLAUDE.md`

Last updated: 2026-10-25

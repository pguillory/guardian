# Guardian - AI Assistant Context

## Meta-Instructions

"Remember": When the user says "remember [something]", save it in this file in the
appropriate section.

Markdown style: Do not use `**` to highlight list items. Write `1. First thing: text`
instead.

Guardian modules live under `lib/guardian/`. Before editing any file under `lib/`,
read every existing AGENTS.md from `lib/` down to the file's directory (for example,
`lib/AGENTS.md` if present, `lib/guardian/AGENTS.md`, and
`lib/guardian/query/AGENTS.md`). AGENTS.md is the canonical instruction file at
every level; keep it a real file. Codex loads instructions only along the path to
its starting directory, so editors must explicitly read applicable descendants.

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

The README describes how Guardian works now. History and upgrade notes go in
`docs/changes/`, never in the README.

## Product

Guardian is a single-tenant, self-hosted, schemaless event store with a SQL-like query
engine, licensed MIT. It ingests JSON events into a custom columnar format and supports
interactive analysis through MCP; HTTP JSON is for ingestion only. It runs as one node or as a
cluster (DNS discovery on any machines, with Fly.io as a preset).

Product docs, in tiers that each extend the one above: the one-sentence, one-paragraph,
and one-page descriptions in `docs/product/overview.md`, and the full product spec in
`docs/product/spec.md`. Read them before changing user-visible behavior, and update
them when that behavior changes. How the system is built (supervision tree, ingest,
storage, queries, interfaces, clustering, configuration, deployment, testing) is in
`docs/architecture/system.md`; read it before structural changes and update it when a
structure it describes changes. ARCHITECTURE.md is an index of these docs, and the
subsystem AGENTS.md files hold the rules for editing each subsystem. The security
design (trust boundaries, invariants, known gaps) is in
`docs/architecture/security.md`; read it before changing authentication, the HTTP or
MCP routers, query functions, logging, secrets, or the Fly deployment, and update it
when those change.

Rules are files of SET, UNSET, TRACK and LOOKUP statements per table (`<table>/<name>.gsql`), run on
each ingested event before storage (`lib/guardian/rules/AGENTS.md`, `docs/changes/ingest-rules.md`).
SET/UNSET are stateless. TRACK/LOOKUP use ephemeral counters on Guardian nodes,
bounded peer calls and aggregate defaults on failure; final UNSETs still run.
Counters are advisory, lose state on restart/eviction/cluster changes and use private
arrival metadata, never caller timestamps. There is no PostgreSQL metadata store, Memcached
runtime, or MaxMind service. Guardian is single-user: authentication is by environment-configured API keys (each at
least 32 bytes and distinct from each other, only in the `x-api-key` header, never in the URL).
The insert-only
`GUARDIAN_INGEST_API_KEY` is accepted only by `POST /api/json/send_events`; the
full-access `GUARDIAN_ADMIN_API_KEY` grants the whole event store through MCP (queries,
rules, ingestion) and `send_events`. Boot needs the admin key; the removed
`GUARDIAN_API_KEY` is not read (`docs/changes/drop-legacy-api-key.md`). Queries run only
through MCP; there is no HTTP query endpoint. There is no user namespace.

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

The runtime consists of Guardian.Rules.Server (loads the rule store first; a failing store is retried until it answers, invalid
settings refuse startup),
Guardian.Counters.Restarter
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

Authentication reads only `GUARDIAN_INGEST_API_KEY` and `GUARDIAN_ADMIN_API_KEY`
(`Guardian.Web.Auth.check_conn/2`); each may rotate freely and independently.

Node naming (`rel/env.sh.eex`) has three modes: Fly.io (`FLY_PRIVATE_IP`), a cluster
member elsewhere (`GUARDIAN_NODE_HOST`), and a single node (`guardian@localhost`, with
distribution on loopback only). Clustered modes need `RELEASE_COOKIE`; peers are found
through `DNS_CLUSTER_QUERY` (on Fly, `<app>.internal` by default). The cookie reaches the
VM through a private file, never argv: `-setcookie` must not appear in any release
command (`docs/changes/release-cookie-file.md`). Keep Fly's output of
`rel/env.sh.eex` unchanged unless the change is meant for Fly: `test/guardian/deployment_test.exs`
pins it.

Fly.io is the best-supported deploy path (`Dockerfile`, `docs/guides/fly.md`). The
guide has `fly launch` write a deployment's `fly.toml`, and the reader adds by hand
only the one setting flyctl has no command for (`kill_signal`/`kill_timeout`, in a
marked block); never have shell commands write or append to `fly.toml`. A deployment's
own `fly.toml` is gitignored or kept outside the repository, and no deployment's
configuration belongs in the tree. Keep the guide free of Guardian settings (the image
sets `GUARDIAN_DATA_DIR`) and its `kill_timeout` at 150 (`test/guardian/deployment_test.exs`
checks both). The README has no deploy commands: it links the guide. The API keys
(`GUARDIAN_ADMIN_API_KEY`, `GUARDIAN_INGEST_API_KEY`) and `RELEASE_COOKIE` are Fly secrets, plus the optional `TUNNEL_TOKEN` that starts the
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

- `lib/guardian/storage/AGENTS.md`
- `lib/guardian/query/AGENTS.md`
- `lib/guardian/query/function/AGENTS.md`
- `lib/guardian/aggregation/AGENTS.md`
- `lib/guardian/ast/AGENTS.md`
- `lib/guardian/web/AGENTS.md`
- `lib/guardian/rules/AGENTS.md`
- `lib/guardian/counters/AGENTS.md`
- `lib/guardian/object_store/AGENTS.md`

Last updated: 2026-10-30

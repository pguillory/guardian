# Guardian overview

This file holds the first three tiers of Guardian's spec chain. Each tier extends the
one above it and must stay consistent with it. The fourth tier, the full product spec,
is [spec.md](spec.md). Where behavior is described here, the code is the authority; if
they disagree, fix the doc.

## One sentence

Guardian is a single-tenant, self-hosted event store: producers send it JSON events
over HTTP or MCP, and people and agents ask questions of those events with a SQL-like
query language.

## One paragraph

Guardian is a single-tenant, self-hosted event store: producers send it JSON events
over HTTP or MCP, and people and agents ask questions of those events with a SQL-like
query language. Its producers are the operator's own services, applications, and
agents, plus Guardian's own metrics and request logs; its readers are the operator and
their agents, mostly through the MCP `query` tool. Guardian is schemaless: any JSON
object can go into any table, nested objects become dotted columns, and a column can
hold mixed types. An insert-only key lets applications send events and nothing else;
a full-access key, used through MCP, runs queries and manages rules. Events land in Guardian's
own columnar segment format (after the table's rules, if any, compute or remove
fields, including ephemeral window-counter results), are queryable as soon as they are stored, start moving to
disk within about an hour, and expire after about 15 days. It runs as a single node or
as a cluster of machines, each holding its own events, and every query fans out to all
connected machines. Fly.io is the best-supported deployment.

## One page

### What it is

Guardian is a single-tenant, self-hosted event store: producers send it JSON events
over HTTP or MCP, and people and agents ask questions of those events with a SQL-like
query language. It exists so that an operator's systems can record what happens
(sessions, tool calls, requests, metrics) without designing a schema first, and so
that the operator and their agents can answer operational questions later with ad hoc
queries.

### Who uses it

1. Producers: the operator's services, applications, and agents, each writing the
   tables it chooses. By convention each stamps its own `timestamp` and `time_ms`.
   Guardian itself writes `system_stats` once a second, a
   `web_requests`/`web_responses` pair for every authenticated JSON API request, and
   a `query_parse_errors` row for each query that fails to parse, and a `queries` row
   for every query run over MCP.
2. Readers: the operator and their agents (for example, Claude or Codex coding
   sessions) query through MCP, which also serves the full query-language reference.
   There is no HTTP query endpoint, so scripts use MCP too, and an operator can use the
   Erlang remote console.

### How it behaves

1. Trust: keys are set in the environment, each at least 32 bytes long.
   The ingest key (`GUARDIAN_INGEST_API_KEY`) is insert-only: it works on the HTTP
   event endpoint and nowhere else, so an application holding it can add events but
   not query them or change rules. The admin key (`GUARDIAN_ADMIN_API_KEY`) has full
   access, through MCP, to every table and the rules. There are no users or
   namespaces. A key goes in the `x-api-key` header, never in the URL. Guardian
   records, for each JSON API request, which key was used, never the key. Without a
   key, only the `/health` liveness check works.
2. Writing: a request names a table and carries a list of events. Each event succeeds
   or fails on its own, and the response reports one ordered result per event. Values
   that cannot be stored are dropped from the event rather than failing it. Guardian
   adds no timestamp or ID. An optional idempotency key gives matching retries on
   the same node a short-lived receipt instead of inserting the batch again;
   protection is best effort and resets on restart.
3. Rules: a table can have rule files with SET, UNSET, TRACK and LOOKUP statements.
   They compute or remove fields and keep approximate, ephemeral window counters
   on incoming events (`TRACK logins = count() BY ip LAST '1h'`). A SET can turn the
   result into a decision (`SET is_blocked = logins >= 50`). The client
   asks for computed fields back with `return_keys`. Rules live in a local folder or
   an S3-compatible bucket, are managed with MCP tools, and are validated together on
   every write.
4. Data model: tables appear when first written. Columns are untyped, a missing
   column is null, and nested objects are flattened into dotted names such as
   `user.name` (or `users..name` for a list of objects).
5. Reading: one read-only statement per request: `SELECT` with `WHERE`, `GROUP BY`,
   `HAVING`, `ORDER BY`, and `LIMIT` over one table, plus `SHOW TABLES` and `DESC`.
   About 20 aggregates and about 60 scalar functions are built in. There are no joins,
   subqueries, updates, or deletes. A query returns at most 10,000 rows: without
   `LIMIT` it is cut to that many. Query time and each query process's heap are
   capped (not a query's total memory); a query over either fails with an error.
6. Lifetime: an event is queryable as soon as its write returns. In-memory segments
   are queued for disk when they fill or one hour after their first event; a hard
   crash loses what has not reached disk. Segments expire about 15 days after they
   were created.

### How it runs

Guardian is an Elixir application with C native code for columns and memory-mapped
segment files, shipped as one Docker image. It runs as a single node, or as a cluster on any set of machines that share a secret
cookie and find each other through DNS; on Fly.io that needs no configuration beyond
the cookie. Each machine keeps its events on its own disk, and every query and schema
lookup covers all connected machines. There is no replication, and a machine that is
down silently drops out of results.

### What it is not

Guardian has no alerting, per-user access control, retention settings per table,
or external services in its ingestion path. Counters use bounded calls between
Guardian nodes and fail open when unavailable. They are advisory: restarts, eviction
and cluster changes lose counts. A producer acts on a computed decision; Guardian
does not block its requests.

The full behavior, limits, and known gaps are in [spec.md](spec.md).

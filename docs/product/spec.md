# Guardian product spec

This is the fourth tier of Guardian's spec chain. It extends the one-page overview in
[overview.md](overview.md) and covers every feature the code ships. Each tier must stay consistent with the one above it.

The spec describes behavior a producer, reader, or operator can observe. It links the
detailed references instead of repeating them:

- Query language: [`lib/web/mcp/query_language.md`](../../lib/web/mcp/query_language.md),
  also served over MCP as `guardian://query-language`. It is the authoritative
  reference for syntax, functions, and aggregates.
- Deployment, configuration, and operations procedures: the guides in
  [docs/guides/](../guides/) and the [configuration reference](../reference/configuration.md).
- Internals: the [system architecture](../architecture/system.md) and the
  per-subsystem `CLAUDE.md` files under `lib/`.
- Trust boundaries: the [security architecture](../architecture/security.md).
- Known gaps: [section 12](#12-known-gaps).

Where behavior is unverified, the spec says so.

## 1. Purpose

Guardian is a single-tenant, self-hosted event store: producers send it JSON events over HTTP
or MCP, and people and agents ask questions of those events with a SQL-like query
language. It replaces the need to design a schema or stand up a database before
recording something. A producer picks a table name and sends objects; a reader asks
`SHOW TABLES`, `DESC`, and `SELECT` questions later.

Design commitments that shape every feature below:

1. Single tenant: One API key, full access, no identities.
2. Schemaless: Tables and columns appear when written; columns are untyped.
3. Predictable ingestion: The write path makes no calls to external services. Events
   change on the way in only by the operator's own rules ([section 5.1](#51-rules)),
   which have no state and call nothing.
4. Read-only queries: Data enters only through ingestion. Through the API, data leaves
   only by age.
5. Self-observing: Guardian records its own metrics, request log, and query parse
   failures as ordinary tables.

## 2. Users

### Producers

Producers are the operator's own systems: services, applications, and agents that
record what happens (sessions, tool calls, requests, metrics). A producer holds the key
and writes the tables it chooses; any key holder can create a table by writing to it.
By convention each producer writes its own table, puts the event name in a `type`
field, and stamps its own `timestamp` (UTC, `YYYY-MM-DD HH:MM:SS`) and `time_ms`, and
each producer documents its own events. These are conventions; Guardian enforces none
of them.

Guardian is also a producer of its own tables:

| Table | Written | Fields |
| --- | --- | --- |
| `system_stats` | once a second per machine | [section 8](#8-built-in-tables) |
| `web_requests`, `web_responses` | per authenticated JSON API request | [section 8](#8-built-in-tables) |
| `query_parse_errors` | per query that fails to parse (JSON API or MCP) | [section 8](#8-built-in-tables) |
| `queries` | per query run (JSON API or MCP) | [section 8](#8-built-in-tables) |

### Readers

1. Agents (for example, Claude or Codex coding sessions) use the MCP endpoint. The
   `query` tool's description summarizes the language and points at the full
   reference resource.
2. Scripts use the JSON query endpoint.
3. An operator can run queries from the Erlang remote console with
   `Console.query("SELECT ...")`, which prints a table.

## 3. Access and trust

1. One key: Every request to `/api/json/*` and `/mcp` must carry the key configured
   in `GUARDIAN_API_KEY` in the `x-api-key` header. The `api_key` query parameter is
   accepted too, but only when the operator sets `GUARDIAN_ALLOW_QUERY_API_KEY=true`,
   because URLs end up in logs and history more readily than headers; it is off by
   default. The header wins if both are present. The comparison does not
   short-circuit on matching prefixes (the
   [security architecture](../architecture/security.md) covers the details).
2. Full access: A valid key can read every table and write any valid table name. No
   identity is recorded and there is no namespace or per-table permission.
   Built-in tables are no exception: any key holder can read `queries`, which keeps
   the text of every query run over the JSON API or MCP, and `query_parse_errors`,
   which keeps the text of every query that failed to parse (up to 16 KiB each), for
   the retention period. Callers should not put secrets in query text. Since there is
   one key and one user, this stores a caller's data for the same principal, not for
   someone else. These are meant to be the only places Guardian keeps query text;
   today fragments of JSON API queries also reach the server log in printed error
   messages.
   Production logs at info, so MCP messages (query text, event payloads) are not
   logged.
3. Rotation: The key can change at any time without touching stored data; a node
   reads it at startup, so the change takes effect when the node restarts with the new
   value. On Fly.io, changing the secret restarts the machine.
4. Unauthenticated surface: `GET /health` answers without a key; it returns `200 ok`,
   or `503 storage unavailable` while storage restarts, and reveals nothing else. CORS
   preflight requests to `/api/json` (an `OPTIONS` request with
   `Access-Control-Request-Method`) also get a 204 with CORS headers
   before the key is checked; they run no handler and read or write nothing. The JSON
   API checks the key before reading the request body, so a request without a valid
   key gets 401 whatever its body. No data is read or written without a key. Paths
   outside `/health`, `/api/json`, and `/mcp` answer 404.
5. Failures: A missing key returns 401 with the message `api_key required`; a wrong
   key returns 401 with `unauthorized`. The JSON API puts the message in `info`
   (`{"status": 401, "info": ...}`); MCP puts it in `error` (`{"error": ...}`).
   Rejected requests are not logged to `web_requests`. With query keys off (the
   default), a request without an `x-api-key` header gets 401 `api_key required`
   whatever its query string, even one that cannot be decoded. With query keys on, a
   request without the header whose query string cannot be decoded (invalid UTF-8,
   nesting deeper than 32, or too long) gets 400 (414 when too long) before the key is
   checked, since the key may be in the query string: from the JSON API with `info`
   "invalid query string", from MCP with `{"error": "invalid query string"}`. With a
   header the key is checked first, so a wrong key gets 401; after a valid key the
   JSON API gives the same 400.
6. Startup: Guardian refuses to start without a `GUARDIAN_API_KEY` of at least 32
   bytes (generate one with `openssl rand -hex 32`; the length is checked, not the
   randomness), or with a `GUARDIAN_ALLOW_QUERY_API_KEY` other than `true` or `false`.
7. Where the key came from: `web_requests` and `web_responses` record `auth_method`,
   `header` or `query`, for each JSON API request, never the key itself. MCP requests
   are not recorded there, so when an MCP request authenticates with the query
   parameter, Guardian writes one line to the server log naming the path, never the
   key, at most once a minute per machine. Together these show whether query keys are
   still in use before turning them off.

How these properties are enforced, and where they fall short, is in the
[security architecture](../architecture/security.md), not this spec.

## 4. Interfaces

### 4.1 HTTP JSON API

Base path `/api/json`. Request bodies are JSON, sent as `application/json` (or any
`application/*+json` type).
CORS is enabled on these routes.

`POST /api/json/send_events` ingests events:

```json
{"table": "requests", "events": [{"path": "/", "status": 200}], "return_keys": ["path"]}
```

- `table` must be a valid table name ([section 6.1](#61-tables)).
- `events` must be a list. Items are processed independently ([section 5](#5-ingestion)).
- `return_keys` is optional. Omitted or `null` returns each stored event in full; a
  list of strings returns exactly those top-level fields of each successful event,
  `null` for any the stored event lacks (until rules existed, a missing key was left
  out); `[]` returns `{}`. The event is the one stored, after rules
  ([section 5.1](#51-rules)), so this is how a client reads a field a rule computed,
  such as `is_blocked`.
- A request-level error (bad table, `events` not a list, bad `return_keys`) returns
  400 with `{"status": 400, "info": "..."}` before any event is stored. A body that is
  malformed JSON gets 400 (`info` "malformed JSON body"), one over 8 MB gets 413, and
  one declared with a non-JSON content type gets 415. A request with no content type is not parsed, so
  `send_events` sees no fields and returns 400, and so does `query`.
- Otherwise the response is 200 with one result per input event, in order, even if
  every event failed:

```json
{"status": 200, "results": [{"success": true, "event": {"path": "/"}},
                            {"success": false, "error": "event is not a JSON object"}]}
```

`POST /api/json/query` runs one statement:

```json
{"query": "SELECT status, count() FROM requests GROUP BY status"}
```

- A body that is not a JSON object with a string `query` returns 400 with `info`
  saying so; the body is not echoed or logged.
- Success returns `{"status": 200, "columns": [...], "rows": [[...], ...]}`. Column
  labels are the `AS` alias or the expression's source text.
- `LET` prefixes are allowed; after them, exactly one statement must remain, or the
  response is 400 with `info`.
- A failure while evaluating the query (an expression that fails on some row, or a
  query that fails inside distributed execution) returns 400 with
  `{"status": 400, "info": "..."}` naming the problem.
- Parse errors, unknown functions, ambiguous columns, and a machine failing the schema
  lookup that resolves the query return a bare 500 `{"status": 500}` with no message.
  Use MCP to see the message. Parse errors (which
  include unknown function names) are also recorded in `query_parse_errors` ([section 8](#8-built-in-tables)), with the message
  the parser produced; recording never changes the response.
- Every query that reaches the query engine, whatever its outcome, is recorded in
  `queries` ([section 8](#8-built-in-tables)); recording never changes or delays the
  response.

With a valid key, unknown paths under `/api/json` return 404 `{"status": 404}`;
without one they return 401 like any other path.

### 4.2 MCP

`/mcp` is a Model Context Protocol server named `guardian` over Streamable HTTP,
authenticated like the JSON API. It offers:

1. Tool `query` with one argument, `sql`. It runs one statement (with optional `LET`
   prefixes) and returns the rows as a JSON list of objects keyed by column label.
   Errors raised while running the query, including parse errors ("Expected X, got
   Y"), come back as MCP tool errors carrying the message. Protocol and transport
   failures, such as the timeout below, come back as MCP protocol errors instead.
   Parse errors are also recorded in `query_parse_errors`
   ([section 8](#8-built-in-tables)) with the same message; recording never changes
   the tool result.
2. Tool `send_events` with `table`, `events`, and optional `return_keys`. Same
   semantics and result shape as HTTP. Request-level errors are MCP tool errors and
   nothing is stored. Event items are not schema-checked by the MCP layer, so a
   non-object item fails on its own rather than rejecting the batch.
3. Tools `list_rules` (optional `table`), `read_rule` (`table`, `name`), `write_rule`
   (`table`, `name`, `source`) and `delete_rule` (`table`, `name`) manage rule files
   ([section 5.1](#51-rules)). A rejected write is a tool error listing every
   validation message, and nothing is saved. A saved write returns `saved: true`, the
   validation errors the set still has (from before this write), and any machine that
   has not yet confirmed loading it (it catches up within a minute). A write whose
   outcome is unknown says it may have been saved.
4. Resource `guardian://query-language`: the full query-language reference as
   Markdown.

Sessions: a request naming an unknown or expired MCP session gets HTTP 404, so clients
re-initialize after a Guardian restart or the MCP library's 30-minute idle expiry.

No server-push stream: `GET /mcp` gets HTTP 405 (after authentication and the session
check above), which the Streamable HTTP spec allows. Guardian never sends
server-initiated messages, so every request's result comes back in the response to its
own POST; accepted client notifications get 202.

Malformed requests: a POST body that is not one JSON object forming a valid JSON-RPC
message gets HTTP 400 with a JSON-RPC error (`-32700` if it is not JSON, `-32600`
otherwise) and `id: null`; a body over 8 MB gets 413. The body is not logged.

Guardian sends no MCP server `instructions` (the pinned MCP library version cannot;
see the [dependency pins](../architecture/system.md#104-dependency-pins)), so the `query` tool
description carries the "what Guardian is" summary.

Timeout: the MCP library gives each request 30 seconds (its default, which Guardian
does not override), and a query may run for 30 seconds
([section 7](#7-queries)). The two race: the query starts a little after the request,
so a query that runs out its time usually reaches the client as the library's timeout
error rather than the query's time-limit error. Either way the query stops at its
limit. Resolving the query comes before that limit: for each table a query reads
from, Guardian asks every machine for that table's schema, waiting up to 60 seconds
for one that doesn't answer. (`DESC` and `SHOW TABLES` collect their schemas while
the query runs, within its limit.) Meanwhile no other MCP tool call on that machine
runs. Ingestion has no such limit: a slow `send_events` keeps
running after the client's timeout.

MCP calls are not recorded in `web_requests` or `web_responses`. Every MCP `query`
call is recorded in `queries`, and those that fail to parse also in
`query_parse_errors`.

### 4.3 Health check

`GET /health` returns `200 ok` without authentication and without reading stored
data. Because the web server starts only after Storage has loaded every segment on the
machine's volume, a passing check at startup also means the machine's data is loaded
(except segment files that cannot be read, which are skipped and logged).
After startup, if storage restarts, the check returns `503 storage unavailable` until
storage has started again and reloaded every readable segment. The Fly.io deployment
uses it to gate rolling deploys, and any load balancer or orchestrator can use it the
same way.

### 4.4 Remote console

An operator with a shell on a node can run `/app/bin/guardian remote` (on Fly, through
`fly ssh console --pty -C "/app/bin/guardian remote"`) and call `Console.query/1`, which runs one resolved statement and prints a
box-drawn table. This is an operator tool, not a product interface; it bypasses the API
key because it already has full VM access.

## 5. Ingestion

Every write path (HTTP, MCP, and Guardian's own `system_stats` and request logging)
goes through the same validation and storage.

1. Table check first: An invalid table name rejects the whole request.
2. Independent events: Each event is validated and stored on its own; a failure never
   stops later events, and there is no batch atomicity.
3. Objects only: A non-object item fails with `event is not a JSON object`.
4. Drop, don't fail: Within an object, any value that cannot be stored is dropped and
   the rest of the event is stored. Dropped values include integers outside 64-bit
   range, lists nested deeper than storage supports (a list of lists is the maximum),
   strings or lists over 2^31 - 1 bytes or elements, and any field whose flattened key
   ([section 6.3](#63-nested-objects-and-lists)) exceeds 250 bytes. The success result
   usually returns the event as stored, so a caller can see what was dropped. It is
   best effort for awkward shapes: a rebuilt event can gain null padding inside lists
   of objects, and when an event cannot be rebuilt faithfully (for example, a list
   mixing scalars and objects with one invalid value inside), the whole top-level field
   is omitted from the result even though its valid parts were stored.
5. No enrichment: Guardian adds no timestamp, ID, source, or node field. Events are
   stored as sent, minus dropped values, changed only by the table's rules
   ([section 5.1](#51-rules)).
6. Error wording tells the caller what is safe to retry:
   - `value cannot be stored; the event was not stored`
   - `internal error before storage; the event was not stored`
   - `internal error; the event may have been stored` (retrying may duplicate it)
7. Visibility: A successful write is visible to queries on that machine as soon as
   the response returns.
8. Size: HTTP request bodies are limited by Plug's default parser limit (8 MB); a
   larger body gets 413. MCP has the same 8 MB limit. Very large events with many
   distinct keys in lists of objects can be slow to flatten.
9. Duplicates: Guardian does not deduplicate. A retried event is stored twice.
10. Rules: events sent through the ingest APIs run their table's rules after
    validation and before storage ([section 5.1](#51-rules)). Guardian's own writes to
    built-in tables do not.

### 5.1 Rules

Rules are statements, in files per table, that set or remove fields on each incoming
event before it is stored:

```sql
-- logins/blocking.gsql
SET is_blocked = true WHERE signal > 0.9;
SET email = lower(email);
UNSET password
```

Files:

1. A rule file is `<table>/<name>.gsql`; the folder names the table. `<name>` matches
   `[a-z0-9_][a-z0-9_-]*` (at most 64 bytes). The table must be a valid table name
   ([section 6.1](#61-tables)) and not a built-in table.
2. A file holds statements separated by `;`, with `--` comments, at most 64 KiB.
   Limits on the whole set: 1,000 files, 256 tables with rules, 1,000 statements per
   table.
3. Files live in a local folder (the default, `<data dir>/rules`) or an S3-compatible
   bucket such as Cloudflare R2 (configured by environment,
   [configuration](../reference/configuration.md)). There is no index file and no
   local cache: listing the store is the rule set.

Statements:

1. `SET field = expr [WHERE cond]` sets a top-level field, named in lowercase (names
   are not quoted, and `SET isBlocked` stores `isblocked`). It replaces the whole
   incoming field: every column under that name in any case (an object, a list, `X`
   for `x`) is removed first.
2. `UNSET path [WHERE cond]` removes a field (`password`) or a field inside an object
   (`user.password`), in any case, and everything beneath it.
3. Expressions and conditions are the query language's scalar expressions: operators,
   CASE, and every scalar function. Aggregates are refused.
4. `SET`, `UNSET` (and the planned `TRACK`, `LOOKUP`, `LAST`) are not reserved words:
   they still work as column and table names, in rules and queries.

Running:

1. A field the event lacks is null, with no warning; nothing is declared. Rules read
   the flattened event, so an object field has no value of its own: read its leaves
   (`card.number`). Names match ignoring case; an exact match wins, otherwise the
   first match in byte order (queries instead reject an ambiguous name).
2. WHERE applies a statement only when it is true; false or null leaves the field as
   sent.
3. Every SET runs before every UNSET, so a SET can read a field an UNSET removes. A SET
   that reads a field another SET writes runs after it; others run in file-name then
   statement order. A SET that reads its own field reads the incoming value.
4. A value a rule produces is validated like an incoming one; one that cannot be
   stored is dropped.
5. Rules run outside the request, each event with a 1-second limit and the query heap
   limit. Functions and operators give null rather than fail (section 7), so a
   statement fails only through a bug; such a failure or an event over a limit fails
   that event, with an error naming the rule file
   and line or the limit, and the event is not stored. Other events in the batch are
   unaffected.
6. A table whose stored rules are invalid (edited in the store by hand, or using a
   function a newer build lacks) fails its events with `rules for <table> are invalid`
   until fixed; other tables run normally. A running machine instead keeps that
   table's last good rules.

Writing:

1. Every write validates the whole set, every table together, and is refused if it
   adds an error the set did not already have: a parse error or unknown function, an
   invalid path or a limit, a field defined two different ways on one table (two
   statements for the same field that differ; identical copies count once), or SETs
   that read each other's fields in a cycle. A set that is already broken can be
   fixed one file at a time, and a broken table does not block writes to others.
2. Writes take a lock held in the store itself, so they are serialized across every
   machine, then every connected machine reloads. Machines also re-read the store
   every minute, catching changes made directly in the store.
3. A local folder belongs to one machine, so with other machines connected, writes are
   refused: a cluster needs a bucket.

Startup: Guardian loads every rule before it loads stored events. A store it cannot
reach, or one that rate-limits it (HTTP 429), is retried for a minute, then startup is
refused; misconfigured store settings refuse startup at once. A rule write the store
rate-limits fails and saves nothing.

## 6. Data model

### 6.1 Tables

A table exists once something has been written to it; there is no create or drop.
Names must match `[a-z_][a-z0-9_]*`, be at most 64 characters, and must not be a query
keyword, `null`, `true`, `false`, `current_date`, `current_timestamp`, or `schema`. This guarantees every table
can be named in a query. A table disappears from `SHOW TABLES` when its last segment
expires.

### 6.2 Values and columns

Columns are untyped. A column can hold nulls, booleans, 64-bit integers, floats,
strings, and lists (of scalars, or of lists of scalars) in different events. A column
absent from an event reads as null. Column names match ignoring case; if two stored
names differ only by case, referencing them is an ambiguous-column error.

Clients should keep keys stable and put data in values (`{"customer_id": 123}`, not
`{"123": true}`), because every distinct key becomes a column.

### 6.3 Nested objects and lists

Nested objects are flattened into dotted column names: `{"user": {"name": "Bob"}}` is
the column `user.name`. A list of objects adds one dot per list level:
`{"users": [{"name": "Bob"}, {"name": "Joe"}]}` stores `users..name` as
`["Bob", "Joe"]`. Lists of scalars are stored as list values. Queries see the flat
columns; an ingest result normally returns the event in its nested shape (see the
exceptions in [section 5](#5-ingestion)).

### 6.4 Time

Timestamps are ordinary strings. By convention they are UTC `YYYY-MM-DD HH:MM:SS`, as
written by Guardian's own tables and returned by `now()`, so string comparison and
sorting are chronological when every value follows it. Guardian does not parse or
enforce time formats on ingest.

## 7. Queries

Full reference: [`query_language.md`](../../lib/web/mcp/query_language.md). Summary of
the shipped surface:

1. Statements: `SELECT`, `SHOW TABLES`, `DESC <table>`, and `LET name = expr;`
   substitutions before one statement.
2. SELECT clauses: `FROM` (one table, or none for constant expressions), `WHERE`
   (repeatable, ANDed), `GROUP BY`, `HAVING`, `ORDER BY ... ASC|DESC`, `LIMIT` (integer
   literal only). `SELECT *` expands to every column of the table across all machines.
3. Expressions: arithmetic, `||`, comparisons including null-safe `<=>`, `IS [NOT]`,
   `AND/OR/NOT`, `BETWEEN`, `IN [list]`, `LIKE` and `ILIKE` (`%` any run, `_` one
   character, no escape; linear time; a pattern over 1,000 characters besides `%` gives
   null), `RLIKE` (Perl-compatible regular expressions), `CASE`, `INTERVAL n UNIT`,
   list literals.
   Integer literals have no sign (minus is an operator) and run from 0 to
   9223372036854775807, the largest 64-bit integer. A larger one, in an expression,
   `LIMIT` or `INTERVAL n UNIT`, is the parse error "Number out of range", as is a
   float too large to represent. The smallest 64-bit integer is written
   `-9223372036854775807 - 1`.
   Precedence, tightest first: `* /`; `+ - ||`; comparisons, `IS [NOT]`,
   `[NOT] LIKE|ILIKE|RLIKE`, `IN`; `BETWEEN`; `NOT`; `AND`; `OR`. So `NOT a = b` is
   `NOT (a = b)`, as in standard SQL.
   Integers are 64-bit, and integer arithmetic (`+ - *`, unary `-`, `abs`, `div`,
   `mod`, and `sum`) wraps around on overflow, two's complement. Numeric functions and
   operators never fail the query: a result with no good value is null, never NaN or
   infinity. That covers division or modulo by zero, the square root of a negative, the
   logarithm of zero or less, a float result too large to represent, a rounded float or
   an interval outside 64-bit integers, `factorial` above 20, date arithmetic outside
   years 0000 to 9999, a port outside 0 to 65535, `ip_to_integer` of invalid UTF-8
   or of a string over 64 bytes, `format_timestamp` of a month or hour with no name,
   and a list nested deeper than storage holds (a list of lists).
4. Aggregates (21 names): `count`, `count_if`, `count_distinct` (approximate,
   HyperLogLog, ignoring null), `sum`, `avg`, `min`, `max`, `min_by`, `max_by`, `min_n`,
   `max_n`, `min_n_by`, `max_n_by`, `arbitrary`, `all`, and standard deviation and
   variance variants. Aggregates merge across segments and machines. `sum`, `avg`, and
   the variance and standard deviation aggregates skip values that are not numbers.
   An integer `sum` wraps like `+`; a float `sum`, `avg`, variance or standard
   deviation that overflows is null.
   `min_n` and `max_n` skip nulls, and `min_by`, `max_by` and the `_n_by` forms skip
   rows whose ordering key is null. The n of `min_n`, `max_n` and the `_n_by` forms must
   be a non-negative integer, the same for every row of a group.
5. Scalar functions (60 names): math, strings, conditionals, types, time, hashes,
   UUIDs, URL and email parsing, `ip_to_integer`, and `cosine_similarity`. There is
   no `jq()`; a query calling it gets a parse error saying so, since nested fields of
   ingested JSON objects are already columns.
   Regular expressions (`RLIKE`, `replace`) are Perl-compatible and match UTF-8
   strings by character. `replace` replaces every non-overlapping match, leftmost
   first, with its replacement taken literally. A value that is not valid UTF-8 gives
   null. A pattern may have at most 32 capturing groups. On a value where a pattern
   backtracks past a fixed limit, `RLIKE` and `NOT RLIKE` are null (so WHERE drops the
   row) and so is `replace`; so is a `replace` whose pattern matches one value too many
   times to hold (hundreds of thousands at the default heap limit, as an
   empty-matching pattern can on a large value; fewer with a lower limit), or that
   matches part of a character (`\C`).
   Functions return null on wrong-type arguments rather than failing the query.
   `to_string` gives every value's string form: an integer's decimal, a float's
   shortest round-trip form (`1.0e300`), `true` or `false`, and a list as compact
   JSON-style text (`[1,null,"a",[2.5]]`, invalid UTF-8 in its strings shown as
   U+FFFD); null stays null. `concat` and `||` use the same forms, with null as the
   empty string.
   Strings that functions build are cut to 64 KiB, at a character boundary, never
   refused: the results of `concat`, `||`, `lpad` and `rpad` when they pad, `replace`,
   `to_string` of a non-string, `lower`, `upper`, `normalize` and `format_timestamp`.
   `replace`, `lower`, `upper` and `normalize` cut even a value they don't lengthen,
   so a rule such as `SET email = lower(email)` stores the first 64 KiB of a longer
   field. Functions that return an input or part of one (`to_string` of a string,
   `substr`, the trims, `if`, `coalesce`) are not cut. `ILIKE` matches the whole
   value, however long.
6. Introspection: the virtual `schema` table has one row per table and column with
   per-type value counts summed across machines. `SHOW TABLES` and `DESC` are
   shorthand for queries on it. `DESC` lists column names only, because columns have
   no type.
7. Read-only: There is no `INSERT`, `UPDATE`, `DELETE`, `JOIN`, `UNION`, subquery,
   `DISTINCT`, `OFFSET`, or quoted identifier. A column named after a keyword cannot be
   referenced.
8. Results: A query returns all its rows in one response, with no pagination, up to
   100,000 rows and about 64 MiB; a larger result fails with an error asking for a
   `LIMIT`, `WHERE`, or `GROUP BY`, never a truncated answer. Rows scanned or
   aggregated don't count. `ORDER BY` with a `LIMIT` over 100,000 is refused.
   Each process a query runs in, on every machine, has a heap limit
   (`GUARDIAN_QUERY_MAX_HEAP_MB`, default 256 MiB, `0` for none); a process killed
   for exceeding it fails the query with "a query process was killed; it may have
   exceeded its heap limit (GUARDIAN_QUERY_MAX_HEAP_MB); narrow the query with WHERE,
   LIMIT or fewer groups". The message hedges because Guardian cannot tell a heap kill
   from another kill. The limit is per process, not a bound on the query's total
   memory. `replace` on a value over 16 KiB runs in a helper process with the same
   limit, or 256 MiB when it is `0`, so one value's matches stay bounded even with the
   limit off. A query may run for at most 30 seconds; then it is stopped on every machine and
   fails with an error saying it exceeded its time limit. An expression that fails
   while being evaluated on any machine fails the whole query with an error, rather
   than dropping that machine's rows. So does any other failure while the query runs:
   a query worker that crashes, a machine that disconnects, or a segment it is reading
   that is deleted, expires, or fails, which the error names. A query that reads a
   segment at the instant its in-memory copy is replaced by its stored file reads the
   stored file instead and returns the same rows; only if no stored copy remains does
   it fail the same way. A query never returns a
   partial answer, and slow steps are waited for, up to the time limit.
   Querying a table that does not exist is not an error: it behaves like an empty
   table: row queries return no rows, and an aggregate query without `GROUP BY`
   returns one row of empty-input defaults (`count()` is 0, `sum(x)` is 0.0, `avg(x)`
   is null).

## 8. Built-in tables

Guardian writes these through the normal ingestion path, so they follow the same
retention and query rules as producer tables.

1. `system_stats`: one row per machine per second with Erlang VM metrics: memory by
   category, reductions, run queues, garbage collection, IO bytes, process, port, atom,
   and ETS counts and limits, plus `timestamp` and `host`. Rows carry the machine's
   hostname but no Erlang node name.
2. `web_requests`: one row per authenticated JSON API request, written before the
   request runs: `timestamp`, `hostname`, `host`, `port`, `method`, `path` (no query
   string), `plug_route`, `scheme`, `remote_ip`, `x_forwarded_for`, `referer`,
   `user_agent`, and `auth_method` (`header` or `query`: where the key was found,
   never the key).
3. `web_responses`: the same fields plus `response_time_ms`, `response_size`, and
   `status`, written when the response is sent.
4. `query_parse_errors`: one row per query that fails to parse, from `POST
   /api/json/query` or the MCP `query` tool, written on the machine that handled it,
   so wording of parse errors can be improved from real cases. "Fails to parse" means
   the message starts `Parse error on line`; that includes unknown function names.
   Other query errors (ambiguous columns, too many statements, node failures) and the
   remote console are not recorded. Fields:
   - `timestamp`, `hostname`.
   - `interface`: `http` or `mcp`.
   - Caller, as far as the request reveals one (there are no identities):
     `remote_ip`, `x_forwarded_for`, `user_agent`, and for MCP the client's
     self-reported `mcp_client_name` and `mcp_client_version` from `initialize`
     (null when unknown, for example on a session Guardian no longer remembers). Each
     is cut to 256 bytes; a non-string value is stored as null.
   - `sql`: the query text exactly as sent, cut to its first 16 KiB on a character
     boundary. `sql_bytes` is the full length sent and `sql_truncated` says whether it
     was cut.
   - `error`: the parse error message, cut to 1 KiB. MCP returned this message in
     full; the JSON API returned a bare 500.
   - `dropped_before`: how many rows this machine dropped (rate cap, or a write that
     failed) since its previous recorded row (normally 0).

   Bounds: at most 60 rows per machine per clock hour; further failures that hour are
   not recorded, the first drop logs a warning, and the next recorded row carries the
   count. The counter lives in memory, so a restart resets it. If writes fall 100
   rows behind (Storage stalled), further rows are dropped and logged until they
   catch up. Rows follow normal
   15-day retention. Recording is handed off without waiting, so the caller's response
   is never delayed or changed by it, and a row normally appears within milliseconds
   of the error. A failure to record is written to the server log, not to the caller.

5. `queries`: one row per query run through `POST /api/json/query` or the MCP `query`
   tool, whatever its outcome, written on the machine that received it. That machine
   coordinates the query, so a query that fans out across a cluster is recorded once;
   the machines that run parts of it record nothing. The remote console is not
   recorded, and neither is a JSON request rejected before its query runs (a body
   without a string `query`). Fields:
   - `timestamp` (when the query started; the row is written when it ends, so a
     long query appears late), `hostname`.
   - `interface`: `http` or `mcp`.
   - Caller: `remote_ip`, and for MCP the client's self-reported
     `mcp_client_name` and `mcp_client_version` from `initialize` (null when
     unknown), each cut to 256 bytes. No request header is recorded: not the key,
     and not even the user agent or `x-forwarded-for` that `query_parse_errors`
     keeps.
   - `sql`, `sql_bytes`, `sql_truncated`: as in `query_parse_errors` (first 16 KiB,
     cut on a character boundary).
   - `duration_ms`: from receiving the query text to having the result or error,
     including resolution and schema lookups; fractional milliseconds.
   - `outcome`: `ok` or `error`. `row_count`: rows returned (null on error).
   - `error_kind` (null on success): `parse` for a parse error (including an unknown
     function); `query` for a failure answered as a query error (HTTP 400: zero or
     several statements, a resource or time limit, a function failing on a value);
     `internal` for anything else (HTTP 500: an ambiguous column, a machine failing
     the schema lookup, an unexpected failure).
   - `error`: the error message, cut to 1 KiB, as MCP returns it (for a failure that
     is not an exception, only its kind); null on success.
   - `dropped_before`: how many rows this machine dropped since its previous recorded
     row (normally 0): writes that failed, and rows refused while 1,000 were already
     waiting to be written (Storage stalled). Rows refused while the recorder process
     itself is restarting are only written to the server log.

   There is no rate cap. Recording is handed off without waiting, so the response is
   never delayed or changed by it, and writing a row never runs a query, so querying
   `queries` records one row like any other query. A query whose request process is
   killed before it ends (an HTTP client that disconnects) is not recorded; an MCP
   query that outlives the MCP request timeout is recorded when it ends. A failure to
   record is written to the server log, naming only its kind, never query text. Rows
   follow normal 15-day retention.

Request bodies, API keys, and MCP traffic are not logged in `web_requests` or
`web_responses`.

## 9. Storage, durability, and retention

1. Format: Events are stored per table in Guardian's own columnar segment files,
   `{table}.{segment_id}.seg`, in the `segments/` directory under
   `GUARDIAN_DATA_DIR` (`/data` in the Docker image and on Fly.io).
   Other `.seg` files, including the old `{user_id}.{table}.{segment_id}.seg` format,
   are ignored with one startup warning and never deleted.
2. In-memory segments: New events go to a writable in-memory segment per table. It is
   handed off for persistence when it reaches 16,384 rows, about 64 MiB of packed
   column data, or one hour after its first event (configurable with
   `GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS`). The hour bounds when persistence starts,
   not when the write reaches disk.
3. Crash window: Events not yet on disk are lost if the machine crashes hard. A
   normal stop (SIGTERM) tries to persist in-memory segments within a 90-second
   budget, about 110 seconds for the whole stop, so whatever stops Guardian must wait
   longer than that before killing it (the Fly configuration allows 150 seconds);
   anything not written by then is lost. One segment whose pack raises an error during
   shutdown currently aborts persistence of the rest.
4. Startup: A machine loads every segment in its data directory before it serves
   HTTP, so boot time grows with stored data. Production refuses to start if the data
   directory is not writable, or on Fly.io if it is not a mounted volume.
5. Retention: About every 10 minutes, Guardian deletes persisted segments more than 15
   days old, measured from when the segment was created, not from event timestamps.
   An event can therefore live slightly longer than 15 days after it was written.
   Retention is global; there is no per-table setting, and no delete through SQL, HTTP,
   or MCP. An operator in the remote console can delete a table or segment with the
   internal Storage functions; that is an operator escape hatch, not a product
   feature.
6. Rescans: About once a minute each machine rescans its data directory, loading
   segment files that appeared and dropping ones that disappeared, so restoring or
   removing files on the volume takes effect without a restart.
7. Backups: There is no replication. On Fly.io, the repository's configuration has
   Fly snapshot each volume daily and keep snapshots 14 days; elsewhere, backups are
   the operator's to arrange.

## 10. Clustering and deployment

Guardian runs from one Docker image (or release) as a single node or as a cluster on
any set of machines that can reach each other. Fly.io is the best-supported
deployment, with its configuration in the repository. Procedures are in the guides under `docs/guides/`.
Product-level behavior:

1. Single node: with no cluster settings, a node runs alone, and its Erlang
   distribution (used by the remote console) is reachable only from the machine
   itself. No cookie is needed.
2. Cluster: each node is given its own address (`GUARDIAN_NODE_HOST`), the same
   Erlang cookie (`RELEASE_COOKIE`), and optionally a DNS name that resolves to every
   node's address (`DNS_CLUSTER_QUERY`). Nodes poll that name every 5 seconds and
   connect to the peers it lists. A node whose address DNS discovery could never
   reach (not an IP address, loopback, or not written in Erlang's canonical form)
   refuses to start. `GUARDIAN_DIST_PORT` pins the distribution port for firewalls.
3. Fly.io is a preset of the cluster: each machine's address defaults to its private
   IPv6 address and the DNS name to `<app>.internal`, so only the cookie is needed.
4. Anyone who can reach a node's distribution ports and knows the cookie can run code
   on every node, and distribution traffic is not encrypted, so the cookie is a
   secret and those ports belong on a private network. Nodes that share a cookie and
   find each other join one cluster, so separate environments need separate cookies
   (the [security architecture](../architecture/security.md) section 6 covers this).
5. Each node stores the events it receives in its own data directory. Whatever routes
   requests (on Fly, Fly's proxy) spreads writes across nodes. Every query and schema
   lookup fans out to all connected nodes, so adding nodes needs no client change.
6. A node that is disconnected, or still starting (loading its stored events after
   a boot or a storage restart), is silently missing from query results. A started
   node that fails a schema lookup fails the statement with a node error. Once a
   query is running, any failure on any node (an expression error, a crashed query
   worker, a node that disconnects or loses traffic to another node) fails the
   whole query with an error. It never returns a partial answer.
7. Single-node deploys stop ingestion briefly; producers must retry. Multi-node
   deploys on Fly roll one machine at a time: ingestion continues on the other
   machines, queries miss the replaced machine's events until it has started, a query
   running as a machine shuts down can fail, and queries spanning old and new releases
   can fail; retry them.
8. On Fly, a failed deploy health check stops the deploy without rolling back.

## 11. Non-features

These are deliberately absent.

1. No alerting, counters (planned: TRACK and LOOKUP), enrichment from outside
   services, or blocking of requests. Rules ([section 5.1](#51-rules)) compute fields,
   such as an `is_blocked` decision the producer acts on, but Guardian itself blocks
   nothing.
2. No users, roles, per-table permissions, or multiple keys.
3. No SQL or API writes beyond ingestion, no updates or deletes, and no per-table
   retention.
4. No joins, subqueries, or cross-table queries.
5. No replication or cross-machine redundancy.
6. No PostgreSQL, Memcached, MaxMind, or other external service dependency.
7. No server-side timestamps, IDs, or deduplication.
8. No web UI.

## 12. Known gaps

Listed here because they change what a user sees:

1. JSON query errors (parse errors, unknown functions, ambiguous columns, node
   failures during resolution) are a bare 500.
2. One segment that fails to pack at shutdown can lose the remaining unpersisted
   segments.
3. One slow MCP tool call delays other MCP tool calls on that machine (a query for up
   to its 30-second limit, after up to 60 seconds per table of schema lookup when a
   machine doesn't answer; an ingest until it finishes).
4. Results, some function sizes, query time, and each query process's heap are
   capped, but a query's total memory is not: GROUP BY state, column data, and many
   processes together can still exhaust a machine's memory and lose its unpersisted
   events.
5. `system_stats` rows lack a node identity.
6. A column labeled from `INTERVAL n WEEK` cannot be re-parsed.
7. `users.name` does not find the list column `users..name`.
8. Edge cases in value handling, flattening, and corrupt-file handling, such as a
   list holding null beside a list of objects (`[null, [{"a": 1}]]`), which cannot be
   rebuilt for the result, slow flattening of lists of objects with many distinct
   keys, and a corrupt segment file that aborts the VM.
9. The rule write lock is a lease in the store. A writer that stalls for more than a
   minute after checking its lease, or a write the store applies more than a minute
   after the writer gave up, can leave a rule set that validation would have refused;
   loading then fails the affected table's events until it is fixed.

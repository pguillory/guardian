# Guardian product spec

This is the fourth tier of Guardian's spec chain. It extends the one-page overview in
[overview.md](overview.md) and covers every feature the code ships. Each tier must stay consistent with the one above it.

The spec describes behavior a producer, reader, or operator can observe. It links the
detailed references instead of repeating them:

- Query language: [`lib/guardian/web/mcp/query_language.md`](../../lib/guardian/web/mcp/query_language.md),
  also served over MCP as `guardian://query-language`. It is the authoritative
  reference for syntax, functions, and aggregates.
- Deployment, configuration, and operations procedures: the guides in
  [docs/guides/](../guides/) and the [configuration reference](../reference/configuration.md).
- Internals: the [system architecture](../architecture/system.md) and the
  per-subsystem `AGENTS.md` files under `lib/`.
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

1. Single tenant: No identities. A full-access key reads and writes everything; an
   insert-only key can only send events.
2. Schemaless: Tables and columns appear when written; columns are untyped.
3. Predictable ingestion: The write path makes no calls to external services. Events
   change on the way in only by the operator's own rules ([section 5.1](#51-rules)),
   whose counters keep ephemeral state on Guardian nodes using bounded peer calls.
   SET and UNSET themselves have no state or external calls.
4. Read-only queries: Data enters only through ingestion. Through the API, data leaves
   only by age.
5. Self-observing: Guardian records its own metrics, request log, and query parse
   failures as ordinary tables.

## 2. Users

### Producers

Producers are the operator's own systems: services, applications, and agents that
record what happens (sessions, tool calls, requests, metrics). A producer holds a key
(normally the insert-only ingest key) and writes the tables it chooses; any key holder
can create a table by writing to it.
By convention each producer writes its own table, puts the event name in a `type`
field, and stamps its own `timestamp` (UTC, `YYYY-MM-DD HH:MM:SS`) and `time_ms`, and
each producer documents its own events. These are conventions; Guardian enforces none
of them.

Guardian is also a producer of its own tables:

| Table | Written | Fields |
| --- | --- | --- |
| `system_stats` | once a second per machine | [section 8](#8-built-in-tables) |
| `web_requests`, `web_responses` | per authenticated JSON API request | [section 8](#8-built-in-tables) |
| `query_parse_errors` | per MCP query that fails to parse | [section 8](#8-built-in-tables) |
| `queries` | per MCP query run | [section 8](#8-built-in-tables) |

### Readers

1. Agents (for example, Claude or Codex coding sessions) use the MCP endpoint. The
   `query` tool's description summarizes the language and points at the full
   reference resource.
2. There is no HTTP query endpoint: scripts query through MCP too.
3. An operator can run queries from the Erlang remote console with
   `Guardian.Query.execute("SELECT ...")`, which returns labels and rows.

## 3. Access and trust

1. Keys: Every request to `/api/json/*` and `/mcp` must carry a key in the
   `x-api-key` header. Keys are of two kinds, each set in its own environment
   variable:
   - The ingest key (`GUARDIAN_INGEST_API_KEY`, optional) is insert-only: it is
     accepted by `POST /api/json/send_events` and nothing else. It is meant for the
     applications that produce events, so a compromised application can add events
     but cannot query or change rules.
   - The admin key (`GUARDIAN_ADMIN_API_KEY`, required; item 6 covers local
     development) has full access: MCP (queries, rules, ingestion) and
     `send_events`. It is meant for the operator and their agents.

   A key is read only from the first `x-api-key` header, never from the URL: URLs
   end up in logs and history more readily than headers. The comparison does not
   short-circuit on matching prefixes, and every configured key is compared, so
   timing does not reveal which one matched (the
   [security architecture](../architecture/security.md) covers the details).
2. Full access: A full-access key can read every table and write any valid table
   name. The ingest key can write any valid table name, but cannot run queries or
   read or change rules. It can still read what ingestion returns: `return_keys`
   gives back columns of the stored row after rules, including a counter value a
   `TRACK` or `LOOKUP` rule wrote into it. It can also write rows into Guardian's built-in
   tables, since those take ingestion like any other table. No
   identity is recorded and there is no namespace or per-table permission.
   Built-in tables are no exception: any full-access key holder can read `queries`,
   which keeps the text of every query run over MCP, and `query_parse_errors`,
   which keeps the text of every query that failed to parse (up to 16 KiB each), for
   the retention period. Callers should not put secrets in query text. Since there is
   one tenant and one principal, this stores a caller's data for the same principal, not for
   someone else. These are the only tables that keep query text, but logs are not
   scrubbed. Production logs at info, so a request that succeeds within the MCP
   library's 30-second timeout logs no MCP message, query text or event, apart from the
   warnings described in the security architecture. An MCP call that outlives that
   timeout, or whose session exits mid-call, logs its message at error, even if the
   call later succeeds (for example a query that runs out its 30 seconds, or a
   slow `send_events` with its event values). An error line or crash report can show
   what the failing process held: query text, event values (before rules unset them),
   rule text or counter keys. Each router drops the request's API keys once they pass,
   so no plug or handler after that check receives them.
3. Rotation: Each key can change at any time, independently of the others, without
   touching stored data; a node reads them at startup, so the change takes effect when the node restarts with the new
   value. On Fly.io, changing the secret restarts the machine.
4. Unauthenticated surface: `GET /health` answers without a key; it returns `200 ok`,
   or `503 storage unavailable` while storage restarts or the node stops, and reveals nothing else. CORS
   preflight requests to `/api/json` (an `OPTIONS` request with
   `Access-Control-Request-Method`) also get a 204 with CORS headers
   before the key is checked; they run no handler and read or write nothing. The JSON
   API checks the key before reading the request body, so a request without a valid
   key gets 401 whatever its body. No data is read or written without a key. Paths
   outside `/health`, `/api/json`, and `/mcp` answer 404.
5. Failures: A missing key returns 401 with the message `api_key required`; a wrong
   key returns 401 with `unauthorized`. The ingest key anywhere but
   `POST /api/json/send_events` (any other `/api/json` path or method, or `/mcp`)
   returns 403 with `this key can only send events`. The JSON API puts the message in
   `info` (`{"status": 401, "info": ...}`, or 403); MCP puts it in `error`
   (`{"error": ...}`).
   Rejected requests are not logged to `web_requests`. A request without an
   `x-api-key` header gets 401 `api_key required` whatever its query string, even one
   that cannot be decoded or that carries a valid key as `api_key`. The key is checked
   first, so a wrong key gets 401; after a valid key, a JSON API request whose query
   string cannot be decoded (invalid UTF-8, nesting deeper than 32, or too long) gets
   400 (414 when too long) with `info` "invalid query string".
6. Startup: Guardian refuses to start without the admin key
   (`GUARDIAN_ADMIN_API_KEY`), except in a local development run (`MIX_ENV=dev`),
   which without it generates a random admin key for that run and prints it to
   stderr. Releases are built only with `MIX_ENV=prod`, so a release always needs the
   key. Guardian also refuses to start with either key variable set but empty or
   shorter than 32 bytes (generate keys with `openssl rand -hex 32`; the length is
   checked, not the randomness); or with both set to the same value. The error names
   the variable, never its value. `GUARDIAN_API_KEY`, the single full-access key of earlier
   releases, is no longer read: a deployment that sets it without the admin key gets
   an error naming `GUARDIAN_ADMIN_API_KEY` and `GUARDIAN_INGEST_API_KEY` instead,
   and beside the admin key it is ignored.
7. Which key: `web_requests` and `web_responses` record `auth_key`, `ingest` or
   `admin`, for each JSON API request, never the key itself (rows from older releases
   may say `legacy`). This is evidence, not proof: an ingest-key holder can write
   forged `web_requests` rows.

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
- `return_keys` is optional. A successful result's `event` is the row as stored,
  after rules ([section 5.1](#51-rules)): flat, keyed by column name
  ([section 6.3](#63-nested-objects-and-lists)), exactly as queries see it, never
  rebuilt into nested JSON. Omitted or `null` returns the whole row; a list of strings
  returns exactly those columns, each named in full (`user.name`, not `user`), `null`
  for any the row lacks; `[]` returns `{}`. `return_keys` is for reading decisions
  and computed values, such as a rule's `is_blocked`, not for echoing a big object
  back.
- `idempotency_key` is optional: omitted or null preserves ordinary ingestion;
  otherwise it must be a nonempty UTF-8 string of at most 128 bytes. Matching
  retries can return a receipt instead of event results; see [section 5](#5-ingestion)
  item 9 and
  [the API reference](../reference/api.md#retrying-a-batch).
- A request-level error (bad table, `events` not a list, bad `return_keys` or
  `idempotency_key`) returns
  400 with `{"status": 400, "info": "..."}` before any event is stored. A body that is
  malformed JSON gets 400 (`info` "malformed JSON body"), one over 8 MB gets 413, and
  one declared with a non-JSON content type gets 415. A request with no content type is not parsed, so
  `send_events` sees no fields and returns 400.
- An idempotency conflict (changed contents, in-flight processing or an unknown
  outcome) returns 409 with `{"status":409,"info":"..."}` without another write.
- An unexpected failure returns 500 with `{"status":500}` and no results (section 5
  item 6). On HTTP/1, a 400, 413, 415 or 500 from the body or query-string parser or
  from such a failure also closes the connection.
- Otherwise a new batch's response is 200 with one result per input event, in order, even if
  every event failed:

```json
{"status": 200, "results": [{"success": true, "event": {"path": "/"}},
                            {"success": false, "error": "event is not a JSON object"}]}
```

`send_events` is the only JSON endpoint. Queries and rules are MCP only
([section 4.2](#42-mcp)); there is no `POST /api/json/query`.

With a full-access key, unknown paths under `/api/json` (including the removed
`/api/json/query`) return 404 `{"status": 404}`; with the ingest key they return 403,
and without a key 401, like any other path.

### 4.2 MCP

`/mcp` is a Model Context Protocol server named `guardian` over Streamable HTTP,
authenticated like the JSON API but only with a full-access key: the ingest key gets
403 on every MCP request. It offers:

1. Tool `query` with one argument, `sql`. It runs one statement (with optional `LET`
   prefixes) and returns the rows as a JSON list of objects keyed by column label.
   Parse errors ("Expected X, got Y") and query failures (section 7) come back as MCP
   tool errors carrying the message. Protocol and transport failures, such as the
   timeout below, and unexpected failures (item 5) come back as MCP protocol errors
   instead.
   Parse errors are also recorded in `query_parse_errors`
   ([section 8](#8-built-in-tables)) with the same message; recording never changes
   the tool result.
2. Tool `send_events` with `table`, `events`, and optional `return_keys` and
   `idempotency_key`. Same
   semantics and result shape as HTTP. Request-level errors are MCP tool errors and
   nothing is stored. Event items are not schema-checked by the MCP layer, so a
   non-object item fails on its own rather than rejecting the batch.
3. Tools `list_rules` (optional `table`), `read_rule` (`table`, `name`), `write_rule`
   (`table`, `name`, `source`) and `delete_rule` (`table`, `name`) manage rule files
   ([section 5.1](#51-rules)). A rejected write is a tool error listing every
   validation message, and nothing is saved. A saved write returns `saved: true`, the
   validation errors the set still has (from before this write), and any machine that
   is connected but has not confirmed loading it (it catches up at the next write or
   restart). A write that fails while saving says it may have been saved, and if it
   was, it takes effect at the latest at the next successful rule write.
4. Resource `guardian://query-language`: the full query-language reference as
   Markdown.
5. A tool call that fails unexpectedly gets JSON-RPC error -32603 "Tool execution
   crashed", and the session continues. A `send_events` or `write_rule` that fails this
   way may have stored events (section 5 item 6) or saved the rule.

Protocol version: Guardian speaks MCP protocol version 2025-03-26 and answers every
`initialize` with it, whatever version the client asks for; it ignores the
`MCP-Protocol-Version` header.

Sessions: a request naming an unknown or expired MCP session gets HTTP 404, so clients
re-initialize after a Guardian restart or the MCP library's 30-minute idle expiry. A
POST other than `initialize` or `server/discover` that names no session gets the same
404; a session-less `server/discover` request declaring a stateless protocol version
gets HTTP 200 with JSON-RPC error -32601, so newer clients fall back to `initialize`.
Sessions are independent: requests in one session run one at a time, and a slow request
never holds up another session.

No server-push stream: `GET /mcp` gets HTTP 405 (after authentication and the session
check above), which the Streamable HTTP spec allows. Guardian never sends
server-initiated messages, so every request's result comes back in the response to its
own POST; accepted client notifications get 202.

Malformed requests: a POST body that is not one JSON object forming a valid JSON-RPC
message gets HTTP 400 with a JSON-RPC error (`-32700` if it is not JSON, `-32600`
otherwise) and `id: null`; a body over 8 MB gets 413. The body is not logged.

Guardian sends no MCP server `instructions`, so the `query` tool description carries
the "what Guardian is" summary.

Timeout: the MCP library gives each request 30 seconds (its default, which Guardian
does not override), and a query may run for 30 seconds
([section 7](#7-queries)). The two race: the query starts a little after the request,
so a query that runs out its time usually reaches the client as the library's timeout
error rather than the query's time-limit error. Either way the query stops at its
limit. Resolving a `SELECT *` comes before that limit: to list each table's columns,
Guardian asks every machine for that table's schema. A machine that doesn't say
within 5 seconds whether it is ready is left out; one whose storage (such as a
table's in-memory segment) doesn't answer for 5 seconds fails the lookup; and
Guardian waits at most 60 seconds for each machine's answer, per table. Other
SELECTs need no lookup. (`DESC`, `SHOW TABLES` and the `schema` table collect their
schemas while the query runs, within its limit.) The library's timeout does not stop
the request: meanwhile later requests in the same session wait, and other sessions
are unaffected.
Ingestion has no such limit: a slow `send_events` keeps running after the client's
timeout.

Cancellation: a client that cancels a request (`notifications/cancelled`) or deletes
its session while a request runs stops it; the waiting POST gets a JSON-RPC error
("Request cancelled", or -32603 "Session terminating"). A query stops at once (a
schema lookup it started on other machines may run on to its own timeout). Writes
do not: a `send_events` batch is always stored whole and a keyed receipt completed, and
a rule write completes, even though the client was told it was cancelled. After a
cancel or delete, the session's next request can run while such a write finishes.

MCP calls are not recorded in `web_requests` or `web_responses`. Every MCP `query`
call is recorded in `queries`, and those that fail to parse also in
`query_parse_errors`.

### 4.3 Health check

`GET /health` returns `200 ok` without authentication and without reading stored
data. Because the web server starts only after Storage has loaded every segment on the
machine's volume, a passing check at startup also means the machine's data is loaded
(except segment files that cannot be read, which are skipped and logged).
After startup, if storage restarts, the check returns `503 storage unavailable` until
storage has started again and reloaded every readable segment. It returns the same 503
from the moment the machine starts to stop. A Fly.io deployment
with several machines, set up as the Fly guide's Scaling section describes, uses it to
gate rolling deploys, and any load balancer or orchestrator can use it the same way.

### 4.4 Remote console

An operator with a shell on a node can run `/app/bin/guardian remote` (on Fly, through
`fly ssh console --pty -C "/app/bin/guardian remote"`) and call
`Guardian.Query.execute("SELECT ...")` from IEx. It returns `{:ok, columns, rows}` or
`{:error, message}`, or `{:error, %Guardian.AST.ParseError{}}` for SQL that does not
parse; an unexpected failure raises. Direct IEx queries are
not recorded in `queries`. The shell has full VM access and bypasses the API keys.

### 4.5 Elixir callers

Guardian-owned Elixir modules use the `Guardian.*` namespace, including
`Guardian.Web.*`. With Guardian running, callers can use
`Guardian.Engine.ingest_events/2` and `Guardian.Query.execute/1` directly. Guardian
still has one event store per VM and uses the `:guardian` application configuration.
Direct queries bypass API query logging. An embedding app must set the `:guardian`
application keys itself: Mix does not evaluate a dependency's `config/runtime.exs`
to translate Guardian's environment variables.

Upgrading from the earlier unprefixed module names requires a full release restart
on every node; mixed builds cannot exchange module-bearing terms or RPCs reliably.
Stored segments and rule files retain their existing formats and need no migration.
New diagnostics that name Guardian exception modules use `Guardian.*`, including
API error messages that name an exception. Existing
built-in table rows keep their old strings, so filters on those names may need both.

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
   is the stored flat row, so a dropped value is reported by its absence: a column of
   the flattened event that is missing from the result was dropped (or removed by a
   rule), and `return_keys` reads it as `null`. The result does not say why, and
   `return_keys: []` reports nothing. Empty objects and empty lists store no column,
   so they are absent too.
5. No enrichment: Guardian adds no timestamp, ID, source, or node field. Events are
   stored as sent, minus dropped values, changed only by the table's rules
   ([section 5.1](#51-rules)). A private arrival timestamp drives counter windows;
   it is metadata outside the event, captured before validation, never automatically
   stored, and cannot be supplied or overwritten by a producer or rule.
6. Failures: an event Guardian refuses fails on its own, with an error saying it was
   not stored, such as `value cannot be stored; the event was not stored`. An unexpected
   failure fails the whole request instead: HTTP 500 or, over MCP, JSON-RPC -32603, with
   no per-event results, and nothing says which events were stored. If it happens while
   storing, earlier events in the batch stay stored and the failing one may have been
   (retrying may duplicate them). On a table with rules, the batch's rules all run
   before anything is stored, so a rule crash stores nothing, but earlier events'
   counter updates stay.
7. Visibility: A successful write is visible to queries on that machine as soon as
   the response returns.
8. Size: HTTP request bodies are limited by Plug's default parser limit (8 MB); a
   larger body gets 413. MCP has the same 8 MB limit. Very large events with many
   distinct keys in lists of objects can be slow to flatten.
9. Duplicates: without an idempotency key, a retried event is stored twice. A key
   identifies one batch per table on one node, shared across HTTP and MCP. For ten
   seconds after processing completes, a matching retry returns
   `{"status":200,"duplicate":true,"failed_events":N}` without running rules or
   storing again. It has no `results` array; N counts failed events. Mixed and
   all-failed batches are remembered too. Retry only the failed subset, with a new key.
   Events and return_keys must have matching decoded values (object key order is
   ignored, but number types and list order matter; omitted/null return_keys match).
   Changed requests and in-flight duplicates get HTTP 409 or MCP tool errors.
   Retry promptly after an in-flight conflict. An MCP call may queue behind an
   earlier call in its session, or time out, before reaching this check. A request
   that fails unexpectedly (item 6), or a caller that aborts, leaves an unknown-outcome
   conflict for ten seconds: events may have been stored. In-flight keys do not expire
   while their caller lives.
   At most 10,000 keys are held per node across all tables; capacity evicts the oldest
   completed entries first, shortening protection. If all slots are in flight, or the
   coordinator is unavailable or slow, ingestion proceeds without protection. Restarts
   forget keys. Another node does not know the key. Expiry, eviction, fail-open
   operation and restarts can allow duplicates; Guardian provides no exactly-once
   guarantee or internal event retries.
10. Rules: events sent through the ingest APIs run their table's rules after
    validation and before storage ([section 5.1](#51-rules)), on any table. Guardian's
    own writes to its built-in tables never run rules.

### 5.1 Rules

Rules are statements, in files per table, that compute or remove fields and update
or read counters on each incoming event before it is stored:

```sql
-- logins/blocking.gsql
SET is_blocked = true WHERE signal > 0.9;
SET email = lower(email);
TRACK logins_last_hour = count() BY ip LAST '1h';
LOOKUP previous_logins = logins_last_hour BY ip;
SET busy = logins_last_hour >= 50;
UNSET password
```

#### 5.1.1 Files

1. A rule file is `<table>/<name>.gsql`; the folder names the table. `<name>` matches
   `[a-z0-9_][a-z0-9_-]*` (at most 64 bytes). The table must be a valid table name
   ([section 6.1](#61-tables)), including a built-in table's name.
2. A file holds statements separated by `;`, with `--` comments, at most 64 KiB.
   Limits on the whole set: 1,000 files, 256 tables with rules, 1,000 statements per
   table.
3. Files live in a local folder (the default, `<data dir>/rules`) or an S3-compatible
   bucket such as Cloudflare R2 (configured by environment,
   [configuration](../reference/configuration.md)). There is no index file and no
   local cache: listing the store is the rule set. Files not ending in `.gsql` are
   ignored; a `.gsql` file at any other path is a validation error, for the table its
   first folder names if that is a valid table. In a local folder, names starting with
   `.` are skipped, more than 20,000 entries fail the load, and the folder may not be
   the data folder, contain it, or be inside its segments folder (startup refuses).

#### 5.1.2 Statements

1. `SET field = expr [WHERE cond]` writes one top-level column, spelled exactly as in
   the statement (names are not quoted, and `SET isBlocked` stores `isBlocked`). Field
   names are flat: `user` and `user.name` are different columns, so `SET user = 1`
   leaves `user.name` and `User` in place.
2. `UNSET column [WHERE cond]` removes exactly the named column: `password`,
   `user.password`, `users..email`. `UNSET card` leaves `card.number`. Removing nested
   values means naming each one, in each spelling that can occur. A rule can name only
   columns made of letters, digits, underscores and dots, so a key such as
   `headers.x-api-key`, or one not known in advance, cannot be removed by a rule.
3. `TRACK name = aggregate(...) [BY expr, ...] [WHERE cond] LAST 'interval'`
   updates a counter and writes its resolved window result to the column `name`,
   including the current event when the update succeeds. The 50th matching event sees 50.
4. `LOOKUP field = counter [FROM table] [BY expr, ...] [WHERE cond]` reads a TRACK
   on this table, or on its FROM table, and writes the result to the column `field`
   without updating it. The number of BY expressions must match the target TRACK.
5. Expressions and conditions are the query language's scalar expressions: operators,
   CASE, and every scalar function. Aggregates are allowed only as TRACK's outer
   aggregate call, never nested or in SET, BY or WHERE.
6. `SET`, `UNSET`, `TRACK`, `LOOKUP` and `LAST` are not reserved words:
   they still work as column and table names, in rules and queries.

#### 5.1.3 Running

1. A field the event lacks is null, with no warning; nothing is declared. Rules read
   the flattened event, so an object field has no value of its own: read its leaves
   (`card.number`). Names match exactly: `status` does not read `Status`.
2. WHERE applies a statement only when it is true; false or null leaves the field as
   sent.
3. LOOKUPs and the SETs their inputs require run first, then remaining SETs/TRACKs in
   dependency levels, then every UNSET. A statement reading a field another statement
   defines runs after it, by exact name (`SET a = b.x` does not depend on `SET b`); a
   self-read sees the incoming field. Within a level, scalar
   work finishes before independent counters run together; their results are applied
   in file-name then statement order. A LOOKUP input or WHERE cannot depend, even
   through SETs, on a TRACK output. All of an event's LOOKUP reads precede its TRACK
   updates, so LOOKUP of that counter sees 49 when TRACK sees 50. Other events may
   update between reads: this is a per-event barrier, not a global snapshot.
4. A value a rule produces is validated like an incoming one; one that cannot be
   stored is dropped.
5. Rules run outside the request, each event with a 1-second limit and the query heap
   limit. Functions and operators give null rather than fail (section 7), so a
   statement fails only through a bug; that fails the whole request (section 5 item 6).
   An event over a limit fails on its own, with an error naming the limit, and is not
   stored; other events in the batch are unaffected.
6. A table whose stored rules are invalid (using a function a newer build lacks, or
   left by a stalled write, section 12) fails its events with `rules for <table> are invalid`
   until fixed, at startup and after any reload alike; there are no last good rules.
   A table whose LOOKUP reads a counter of an invalid table is invalid too. Other
   tables, queries and the rule tools work normally. A restart of the rules process
   keeps the published rules even while the rule store is unreachable.

#### 5.1.4 Counters

1. Operators: every query aggregate and arity (section 7), with the same arguments,
   skipping, precision and numeric results as a query over the window's events.
   Missing/expired results and any failed operation produce the aggregate's result
   over no rows: 0 for count, count_if and count_distinct, true for all, null for
   the rest. Average retains exact integer sums. A count beyond int64 is refused
   where the event is stored, like any value storage cannot hold. A top-N counter
   (`min_n`, `max_n` and the `_n_by` forms) whose events disagree on n produces null.
2. BY is an exact ordered tuple of typed values. Omitted BY is one global group;
   null is a valid shared component. Integer 1, float 1.0 and string '1' are distinct
   groups. LOOKUP evaluates its own BY expressions, so types and order must match.
   WHERE false or null preserves the incoming output field and skips any update;
   do not trust that field as a computed decision when the statement is skipped.
3. LAST is a positive integral total interval in s/m/h/d/w notation, at most
   365 days. Windows use Guardian's private arrival time, never producer timestamps.
   With window W, bucket width B=ceil(W/3), reads include every bucket from
   floor((arrival-W)/B) through floor(arrival/B), at most four. The complete oldest
   intersecting bucket is included: a 30-minute window can include almost 40 minutes.
   This is a boundary overcount bias, not a numerical upper bound (negative sums,
   approximation and loss can reduce results). No proportional weighting is used.
   Buckets expire at bucket_end+W; writes use remaining TTL rather than renewing a
   full window. Transit/queue delay can delay physical owner expiry. An event delayed
   beyond its bucket expiry skips its update and receives the missing result.
   Operators must synchronize node clocks; there is no event-time or late-event mode.
4. Counter identity includes table, name and the hash of canonical TRACK source.
   Changing expressions, aggregate, BY, WHERE, LAST or name starts fresh; moving
   identical source between files, comments and whitespace do not. Identical TRACK
   copies count once. Valid definition and dependent LOOKUP edits switch together
   on each node. In-flight events keep their old identities; old state expires or
   is evicted. Queries read historical stored output fields, never live counters.
5. Counter operations fail open: a read or update the counter store cannot answer
   (unreachable, timed out, restarting or over a limit) overwrites that statement's
   output with its missing result, and other rules (including final UNSETs) continue.
   A counter expression that raises, or a top-N whose n differs from the state it
   merges with, is a rule failure instead ([section
   5.1.3](#513-running) item 5). A successful increment can survive a later
   rule or storage failure. There is no rollback or internal event retry; unkeyed
   resubmissions count again. A matching completed same-node idempotency-key retry
   skips rules but returns only its receipt, without decision values (section 5).
   Eviction, overload, restart or another node can bypass receipt protection.
6. Calls wait at most 50 ms, within a 100 ms counter phase per event and a shared
   250 ms failed-call wait allowance per batch, including replacement workers.
   Unavailable owners enter a one-second cooldown; timeouts do so with at least
   25 ms call allowance. Healthy calls refund the batch allowance, so slow successful
   events can still accumulate latency across a batch. There is no uncertain-write
   retry or owner failover. Only definite CAS conflicts retry, at most three total
   attempts within the same budgets. SET/UNSET keep their fail-closed behavior.
7. State is ephemeral and advisory: restarts, eviction, membership changes,
   partitions and uncertain writes can lose or split counts (section 10). The
   resident counter memory target is GUARDIAN_COUNTER_MEMORY_MB, positive MiB, default
   64; explicit empty or invalid values refuse startup. It excludes mailboxes,
   temporary copies and other VM memory. Housekeeping enforces it about every
   second, so writes can temporarily exceed it. Expired buckets are reclaimed first,
   then a sampled cutoff discards buckets with the earliest expiry. Tied expiries
   can discard more than half, including every live bucket. Counters are not durable enforcement limits.
   UNSET does not erase BY values or the inputs that arbitrary, min/max and the
   `_by` and `_n` forms keep from counter memory: they can
   remain for a window plus a bucket and cross the trusted peer network unencrypted.
   Avoid secrets in those expressions.

#### 5.1.5 Writing

1. Every write validates the whole set, every table together, and is refused if it
   adds an error the set did not already have: a parse error or unknown function, an
   invalid path or a limit, a field defined two different ways on one table (two
   statements for the same field that differ; identical copies count once), a cycle
   between statements reading each other's fields, an invalid counter aggregate/window,
   a missing TRACK target, a grouping-arity mismatch or a LOOKUP-after-TRACK
   dependency. SET/TRACK/LOOKUP share one output namespace. A set that is already
   broken can be fixed one file at a time; a broken table does not block writes to others.
2. Writes take a lock held in the store itself, so they are serialized across every
   machine, then every connected machine reloads. If the lock is held when a write or
   delete tries to take it, the operation fails without changing anything; the MCP
   tools try again for a few seconds, then report that something else is editing the
   rules. A lock left by an interrupted write expires within two minutes. Rules change
   only through these writes; editing the store directly is not supported. A machine
   that misses the reload keeps its rules until the next write or until it restarts.
   The write's reply names a connected machine that didn't confirm; one not connected
   at the time isn't named.
3. A local folder belongs to one machine: a cluster needs a bucket.
4. A referenced TRACK cannot be deleted or changed to an incompatible grouping
   through a single-file write. Add a new named TRACK, retarget LOOKUPs to it, then
   delete the old one, or remove dependent LOOKUPs first. Rapid edits with many
   dependents can exhaust the bounded compiled-module pool; the file may be saved
   without taking effect, and the reply names the machine. The next rule write
   activates it, once reclamation has freed names.

#### 5.1.6 Startup

Guardian loads every rule before it loads stored events. Any failure reading the store
(wrong credentials, a missing bucket, a mistyped host and a certificate failure
included) is retried until the store answers, at most 10 seconds apart, logging the
failure each time; Guardian is not up in the meantime. Invalid store settings refuse
startup at once.

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
absent from an event reads as null. Column names are case-sensitive and match exactly:
`userId` and `userid` are two columns, and a query in another case than the stored one
reads null.

Clients should keep keys stable and put data in values (`{"customer_id": 123}`, not
`{"123": true}`), because every distinct key becomes a column.

### 6.3 Nested objects and lists

Nested objects are flattened into dotted column names: `{"user": {"name": "Bob"}}` is
the column `user.name`. A list of objects adds one dot per list level:
`{"users": [{"name": "Bob"}, {"name": "Joe"}]}` stores `users..name` as
`["Bob", "Joe"]`, and an item without the key holds `null` in its list, up to the last
item that has it. A key that contains a dot or a double quote, or is empty, is written
in double quotes within the column name, with a backslash before each `"` and `\`
in it: `{"a.b": {"c": 1}}` is the column `"a.b".c`. Lists of scalars are stored as
list values. Queries and ingest results both see the flat columns:
`{"user": {"name": "Bob"}, "tags": ["a"]}` comes back from `send_events` as
`{"user.name": "Bob", "tags": ["a"]}`.

### 6.4 Time

Timestamps are ordinary strings. By convention they are UTC `YYYY-MM-DD HH:MM:SS`, as
written by Guardian's own tables and returned by `now()`, so string comparison and
sorting are chronological when every value follows it. Guardian does not parse or
enforce time formats on ingest.

Time arithmetic (`date_add`/`adddate`, `date_sub`/`subdate`, a timestamp `+` or `-`
seconds, and `to_seconds`/`unix_timestamp`) accepts only UTC `YYYY-MM-DD HH:MM:SS`:
exactly 19 bytes, with a space between date and time. Numeric offsets of any
form, including zero (`+00:00`), give null rather than being converted. A `T`
separator, trailing `Z`, fractional seconds and all other formats also give null.
Calendar fields must be valid, with years 0000 to 9999; arithmetic outside that
range gives null. Timestamp results use the same UTC format; `to_seconds` gives
seconds since 1970 UTC. `date(ts)` and `format_timestamp` also require the
space-separated format without a suffix. Comparison and sorting remain plain
string operations.

## 7. Queries

Full reference: [`query_language.md`](../../lib/guardian/web/mcp/query_language.md). Summary of
the shipped surface:

1. Statements: `SELECT`, `SHOW TABLES`, `DESC <table>`, and `LET name = expr;`
   substitutions before one statement. A LET function (`LET f(a) = ...`, where `f`
   names a registered function) called with a different number of arguments than it
   was defined with is a query error. Keywords and function names match in any case.
   Column, table, alias and LET names match exactly and keep their case (`AS Total`
   labels the column `Total`).
2. SELECT clauses: `FROM` (one table, or none for constant expressions), `WHERE`
   (repeatable, ANDed), `GROUP BY`, `HAVING`, `ORDER BY ... ASC|DESC`, `LIMIT` (integer
   literal only). `FROM` and `DESC` take a table name (for FROM, after LET
   substitution); anything else is a query error. `SELECT *` expands to every column
   of the table across all machines, each labeled with its name, also where a LET name
   stands for `*`; without `FROM` it is a query error.
3. Expressions: arithmetic, `||`, comparisons including null-safe `<=>`, `IS [NOT]`,
   `AND/OR/NOT`, `BETWEEN`, `[NOT] IN [list]` (a parenthesized list such as `('a', 'b')` or
   `('a')` is a parse error), `LIKE` and `ILIKE` (`%` any run, `_` one
   character, no escape; linear time; a pattern over 1,000 characters besides `%` gives
   null), `RLIKE` (Perl-compatible regular expressions), `CASE`, `INTERVAL n UNIT`,
   list literals.
   Integer literals have no sign (minus is an operator) and run from 0 to
   9223372036854775807, the largest 64-bit integer. A larger one, in an expression,
   `LIMIT` or `INTERVAL n UNIT`, is the parse error "Number out of range", as is a
   float too large to represent. The smallest 64-bit integer is written
   `-9223372036854775807 - 1`.
   Precedence, tightest first: `* /`; `+ - ||`; comparisons, `IS [NOT]`,
   `[NOT] LIKE|ILIKE|RLIKE`, `[NOT] IN`; `BETWEEN`; `NOT`; `AND`; `OR`. So `NOT a = b` is
   `NOT (a = b)`, as in standard SQL.
   Integers are 64-bit, and integer arithmetic (`+ - *`, unary `-`, `abs`, `div`,
   `mod`, and `sum`) wraps around on overflow, two's complement. Numeric functions and
   operators never fail the query: a result with no good value is null, never NaN or
   infinity. That covers division or modulo by zero, the square root of a negative, the
   logarithm of zero or less, a float result too large to represent, a rounded float or
   an interval outside 64-bit integers, `factorial` above 20, date arithmetic outside
   years 0000 to 9999, a port outside 0 to 65535 or written with more than 20 digits, `ip_to_integer` of invalid UTF-8
   or of a string over 64 bytes, `format_timestamp` of a month or hour with no name,
   and a list nested deeper than storage holds (a list of lists).
4. Aggregates (21 names): `count`, `count_if`, `count_distinct` (approximate,
   HyperLogLog at precision 8, about 6.5% standard error, ignoring null), `sum`,
   `avg`, `min`, `max`, `min_by`, `max_by`, `min_n`, `max_n`, `min_n_by`, `max_n_by`, `arbitrary`, `all`, and standard deviation and
   variance variants. Aggregates merge across segments and machines. `sum`, `avg`, and
   the variance and standard deviation aggregates skip values that are not numbers.
   An integer `sum` wraps like `+`; a float `sum`, `avg`, variance or standard
   deviation that overflows is null.
   `min_n` and `max_n` skip nulls, and `min_by`, `max_by` and the `_n_by` forms skip
   rows whose ordering key is null. The n of `min_n`, `max_n` and the `_n_by` forms must
   be a non-negative integer, the same for every row of a group.
   Which of tied values `min`, `max` and the `_by` forms return is undefined (1 or
   1.0, for example); in the `_n` forms, so are the order of tied values and which of
   them a limit of n keeps. A float `sum`, `avg`, variance or standard deviation can
   depend on the order partial results merge in: usually only in its last bits, but
   more when large values cancel, an overflow can give null where another order would
   not, and an integer sum can wrap before a float joins it.
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
   times to hold (hundreds of thousands at the 256 MiB heap limit, as an
   empty-matching pattern can on a large value), or that
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
   `DISTINCT`, `OFFSET`, or quoted identifier. A column named after a keyword, in any
   case, cannot be referenced.
8. Results: A query returns all its rows in one response, with no pagination, up to
   100,000 rows and about 64 MiB; a larger result fails with an error asking for a
   `LIMIT`, `WHERE`, or `GROUP BY`, never a truncated answer. Rows scanned or
   aggregated don't count. `ORDER BY` with a `LIMIT` over 100,000 is refused.
   Each process a query runs in, on every machine, has a fixed 256 MiB heap limit; a
   process killed for exceeding it fails the query with "a query process was killed;
   it may have exceeded its 256 MiB heap limit; narrow the query with WHERE, LIMIT or
   fewer groups". The message hedges because Guardian cannot tell a heap kill
   from another kill. The limit is per process, not a bound on the query's total
   memory. `replace` on a value over 16 KiB runs in a helper process with the same
   limit, so one value's matches stay bounded. A query may run for at most 30
   seconds; then it is stopped on every machine and fails with an error saying it
   exceeded its time limit. An expression that fails while being evaluated on any machine fails the whole query with an error, rather
   than dropping that machine's rows. So does any other failure while the query runs:
   a query worker that crashes, a machine that disconnects, or a segment it is reading
   that is deleted, expires, or fails, which the error names. A query that reads a
   segment at the instant its in-memory copy is replaced by its stored file reads the
   stored file instead and returns the same rows; only if no stored copy remains does
   it fail the same way. A query never returns a
   partial answer, and slow steps are waited for, up to the time limit.
   A machine that has started to stop refuses new queries with an error saying to
   retry. This is best effort, so a query still running as it stops can fail.
   Querying a table that does not exist is not an error: it behaves like an empty
   table: row queries return no rows, and an aggregate query without `GROUP BY`
   returns one row of empty-input defaults (`count()` is 0, `sum(x)` and `avg(x)`
   are null).

## 8. Built-in tables

Guardian writes these through the normal ingestion path, without ingest rules, so
they follow the same retention and query rules as producer tables.

1. `system_stats`: one row per machine per second with Erlang VM metrics: memory by
   category, reductions, run queues, garbage collection, IO bytes, process, port, atom,
   and ETS counts and limits, plus `timestamp` and `host`. It also has operating-system
   and native resource metrics: `open_fd_count` (the Guardian process's open file
   descriptors, sockets included), `mmap_count` (segment files mapped into memory),
   `native_column_count` (live native column resources, whose buffers sit outside the
   VM's allocators) and `rss_bytes` (the process's resident memory). `rss_bytes` is
   read only on Linux and is null elsewhere; `open_fd_count` and `rss_bytes` are null
   when they cannot be read. `rss_bytes` includes pages of mapped segment files, so it
   moves with reads and page reclaim: read it as a trend. A number that keeps rising
   over time is how a leak shows. Rows carry the machine's hostname but no Erlang node
   name. `counters_available` is a boolean reporting
   whether the internal counter processes are present, sampled without waiting for
   them. Counter crashes recover automatically with backoff and do not make
   `/health` fail; this field does not measure counter responsiveness.
2. `web_requests`: one row per authenticated JSON API request, written before the
   request runs: `timestamp`, `hostname`, `host`, `port`, `method`, `path` (no query
   string), `plug_route`, `scheme`, `remote_ip`, `x_forwarded_for`, `referer`,
   `user_agent`, and `auth_key` (`ingest` or `admin`: which key it was), never the
   key. Rows from older releases may instead say `legacy` in `auth_key`, and may also
   have `auth_method` (`header` or `query`), from when a key could come from the URL.
3. `web_responses`: the same fields plus `response_time_ms`, `response_size`, and
   `status`, written when the response is sent.
4. `query_parse_errors`: one row per query that fails to parse, from the MCP `query`
   tool, written on the machine that handled it,
   so wording of parse errors can be improved from real cases. "Fails to parse" means
   the message starts `Parse error on line`; that includes unknown function names.
   Other query errors (too many statements, node failures) and the
   remote console are not recorded. Fields:
   - `timestamp`, `hostname`.
   - `interface`: `mcp` (rows from before the JSON query endpoint was removed say
     `http`).
   - Caller, as far as the request reveals one (there are no identities):
     `remote_ip`, `x_forwarded_for`, `user_agent`, and for MCP the client's
     self-reported `mcp_client_name` and `mcp_client_version` from `initialize`
     (null when unknown, for example on a session Guardian no longer remembers). Each
     is cut to 256 bytes; a non-string value is stored as null.
   - `sql`: the query text exactly as sent, cut to its first 16 KiB on a character
     boundary. `sql_bytes` is the full length sent and `sql_truncated` says whether it
     was cut.
   - `error`: the parse error message, cut to 1 KiB. MCP returned this message in
     full.
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

5. `queries`: one row per query run through the MCP `query`
   tool, whatever its outcome, written on the machine that received it. That machine
   coordinates the query, so a query that fans out across a cluster is recorded once;
   the machines that run parts of it record nothing. The remote console is not
   recorded. Fields:
   - `timestamp` (when the query started; the row is written when it ends, so a
     long query appears late), `hostname`.
   - `interface`: `mcp` (older rows may say `http`).
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
     function); `query` for a failure answered as a query error (zero or
     several statements, a FROM or DESC that is not a table name, `SELECT *` without a
     table, a LET function given the wrong number of arguments, a resource or time
     limit, a function failing on a value, a machine failing the schema lookup, a
     machine that is stopping);
     `internal` for an unexpected failure, which the caller sees as JSON-RPC -32603.
   - `error`: the error message, cut to 1 KiB, as MCP returns it; for `internal`, the
     exception's message, which the caller does not see (for a failure that is not an
     exception, only its kind); null on success.
   - `dropped_before`: how many rows this machine dropped since its previous recorded
     row (normally 0): writes that failed, and rows refused while 1,000 were already
     waiting to be written (Storage stalled). Rows refused while the recorder process
     itself is restarting are only written to the server log.

   There is no rate cap. Recording is handed off without waiting, so the response is
   never delayed or changed by it, and writing a row never runs a query, so querying
   `queries` records one row like any other query. A query whose request process is
   killed before it ends is not recorded; an MCP query that outlives the MCP request timeout is recorded when it ends. A failure to
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
7. Backups: There is no replication. On Fly.io, volumes created as in the Fly guide
   are snapshotted daily, with snapshots kept 14 days; elsewhere, backups are the
   operator's to arrange.

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
   secret and those ports belong on a private network. Guardian's own processes (the
   server, the remote console and rpc commands) never carry the cookie on their
   command lines. Nodes that share a cookie and find each other join one cluster, so
   separate environments need separate cookies
   (the [security architecture](../architecture/security.md) section 6 covers this).
5. Each node stores the events it receives in its own data directory. Whatever routes
   requests (on Fly, Fly's proxy) spreads writes across nodes. Every query and schema
   lookup fans out to all connected nodes, so adding nodes needs no client change.
6. A node that is disconnected, or still starting (loading its stored events after
   a boot or a storage restart), is silently missing from query results. A started
   node that fails a schema lookup (`SHOW TABLES`, `DESC`, the `schema` table,
   `SELECT *`) fails the statement with a node error. Once a query is running, any
   failure on any node (an expression error, a crashed query worker, a node that
   disconnects or loses traffic to another node) fails the whole query with an
   error. It never returns a partial answer. A segment that stops answering holds a
   query that scans it until the query's time limit.
7. Single-node deploys stop ingestion briefly; producers must retry. Multi-node
   deploys on Fly, set up as the Fly guide's Scaling section describes, roll one
   machine at a time and wait for each to load its segments: ingestion continues on
   the other machines, queries miss the replaced machine's events until it has
   started, a query running as a machine shuts down can fail, and queries spanning old
   and new releases can fail; retry them.
8. On Fly, a failed deploy stops without rolling back.
9. Counters choose one owner per definition and typed group from the event's
   connected-node snapshot, with all buckets on that owner. There is no replication,
   state migration or recovery after a partition. Node joins/leaves, different
   membership views, rolling deploys and Store restarts can lose/split state.
   An owner that is slow or unavailable supplies defaults, preserving ingestion.
   Rules-process restarts retain published identities; Store/node restarts lose
   counts. Run one build across the cluster: older nodes that cannot load counter
   rules fail those tables' events, or, on older builds, keep running earlier rules.

## 11. Non-features

These are deliberately absent.

1. No alerting, durable counters, enrichment from outside
   services, or blocking of requests. Rules ([section 5.1](#51-rules)) compute fields,
   such as an `is_blocked` decision the producer acts on, but Guardian itself blocks
   nothing.
2. No users, roles, per-table permissions, or multiple keys.
3. No SQL or API writes beyond ingestion, no updates or deletes, and no per-table
   retention.
4. No joins, subqueries, or cross-table queries.
5. No replication or cross-machine redundancy.
6. No PostgreSQL, Memcached, MaxMind, or other external service dependency.
7. No automatically stored server-side timestamps or IDs (private counter arrival
   metadata is described in section 5). Deduplication is limited to short-lived,
   best-effort idempotency-key receipts ([section 5](#5-ingestion)).
8. No web UI.

## 12. Known gaps

Listed here because they change what a user sees:

1. One segment that fails to pack at shutdown can lose the remaining unpersisted
   segments.
2. One slow MCP tool call delays later calls in the same MCP session (a query for up
   to its 30-second limit, after, for a `SELECT *`, up to 60 seconds per table of
   schema lookup when a machine reports ready and then stops answering; an ingest
   until it finishes). Other sessions are not delayed.
3. Results, some function sizes, query time, and each query process's heap are
   capped, but a query's total memory is not: GROUP BY state, column data, and many
   processes together can still exhaust a machine's memory and lose its unpersisted
   events.
4. A column labeled from `INTERVAL n WEEK` cannot be re-parsed.
5. `users.name` does not find the list column `users..name`.
6. Edge cases in value handling, flattening, and corrupt-file handling, such as slow
   flattening of lists of objects with many distinct keys, and a corrupt segment file
   that aborts the VM.
7. The rule write lock is a lease in the store. A write that outlasts the two-minute
   lease, or one the store applies after the writer gave up, can overlap another writer
   and leave a rule set that validation would have refused; loading then fails the
   affected table's events until it is fixed.
8. A segment that crashes on an unexpected insert failure loses the rows it holds in
   memory, including rows already acknowledged.
9. A machine that misses a rule write's reload, because it wasn't connected yet or its
   reload failed, keeps its rules until the next rule write or until it restarts.

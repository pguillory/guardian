# query-log: record every query in a built-in `queries` table

## Problem

Guardian records its own activity in built-in tables (`system_stats`, `web_requests`,
`web_responses`, `query_parse_errors`), but nothing records the queries it runs. An
operator cannot see which queries agents and scripts send, how long they take, how
many rows they return, or which fail and why. `web_requests` covers JSON API requests
only (not MCP, and not the query text); `query_parse_errors` covers only queries that
fail to parse, capped at 60 an hour.

## Behavior after the change

1. Every query that `POST /api/json/query` or the MCP `query` tool runs writes one
   row to the built-in table `queries`, on the machine that received the request
   (the coordinator). Peers that run parts of a distributed query, and peers that
   answer schema lookups, write nothing, so a query is logged once however many
   machines it touches. Queries called directly from the remote IEx shell are not
   logged, as they are not logged anywhere today.
2. Fields:
   - `timestamp` (when the query started, UTC `YYYY-MM-DD HH:MM:SS`), `hostname`.
   - `interface`: `http` or `mcp`.
   - Caller: `remote_ip`, and for MCP `mcp_client_name` and `mcp_client_version`
     (from the client's `initialize`, not a header), with the 256-byte bounds of
     `query_parse_errors`. No request header at all: not the API key, and not the
     `user_agent` and `x_forwarded_for` that `query_parse_errors` keeps (plan review
     held those to the requirement "never log request headers").
   - `sql`: the query text as sent, cut to its first 16 KiB on a UTF-8 character
     boundary; `sql_bytes` (full length) and `sql_truncated`.
   - `duration_ms`: wall time from receiving the SQL to having the result or error
     (resolution, schema lookups and execution), a float with microsecond precision.
   - `outcome`: `ok` or `error`.
   - `row_count`: rows returned; null on error.
   - `error_kind`: null on success; `parse` (an `Guardian.AST.ParseError`, which includes
     unknown functions), `query` (a failure the query APIs answer as a query error:
     zero or several statements, or a `Guardian.Query.Error` such as a resource or time
     limit), or `internal` (anything else raised: an ambiguous column, a machine
     failing the schema lookup, an unexpected exception).
   - `error`: the error message cut to 1 KiB (for an exit or throw, only its kind,
     as `Guardian.Engine.failure_kind/3` names it); null on success.
   - `dropped_before`: rows this machine dropped (backlog full, or a write that
     failed) since its previous recorded row; normally 0.
3. Recording never changes or fails a response, and never makes the caller wait on
   Storage: the request process builds the row and casts it to a recorder process
   (`Guardian.Web.QueryLog`, a GenServer under Main beside `Guardian.Web.QueryParseErrors`), which
   writes it with `Guardian.Engine.try_log_event/2`. The response is the same as before for
   every outcome; raises, exits and throws are reraised with `:erlang.raise/3` and
   their original stacktrace. If the recorder's mailbox already holds 1,000 rows
   (Storage stalled; a best-effort check, so a soft bound), the sender drops the row
   and bumps an atomic counter the recorder owns, which the next written row reports
   in `dropped_before`; the first drop of a backlog logs once (again only after the
   backlog falls to half the cap). A failed write is
   logged by kind only (never query text) and counted the same way. If the recorder
   itself is not running (restarting), the row is dropped and logged, not counted.
   No hourly cap: one query writes one small row, the same order
   of cost as the `web_requests`/`web_responses` pair an HTTP query already writes.
4. No recursion or amplification: writing a row is an ingest, never a query, so a
   query against `queries` logs exactly one row like any other, and nothing the
   recorder does is logged.
5. Not recorded: a query whose request process is killed before it finishes (the
   client disconnects and the HTTP server kills the handler) writes no row. A query
   that outlives MCP's 30-second request timeout still writes its row when it ends.
   A JSON request rejected before the query runs (bad body) writes none.
6. Rows follow normal 15-day retention.

### Relation to the other built-in tables

- `query_parse_errors` becomes conceptually redundant: every parse failure also
  appears in `queries` with `error_kind = 'parse'`, without the hourly cap (but
  without user agent and `x-forwarded-for`, and the two recorders drop rows
  independently under failure, so it is not a strict subset). It is not removed in
  this change (removing a documented table is a product decision); recommended
  follow-up: drop it and its recorder (TODO.md `drop-query-parse-errors`).
- `web_requests`/`web_responses` stay: they cover every JSON API request (ingestion
  included), with HTTP status, response size and `auth_method`, and no query text.
  `queries` adds MCP and the query itself.

## Implementation

- `Guardian.Web.Query.execute/3` (the one place both interfaces run SQL) measures the call,
  catches every outcome (`{:ok, ...}`, `{:error, msg}`, raise, exit, throw), records,
  and returns or reraises the original. Building and casting the row is wrapped so it
  cannot raise. The caller function it already takes is used for both recorders.
- `Guardian.Web.QueryLog`: like `Guardian.Web.QueryParseErrors` (cast, `whereis` and mailbox check,
  writer option, `sync/1` for tests), without the hourly cap. It reuses
  `Guardian.Web.QueryParseErrors.truncate/2`, `bound_caller_fields/1` (newly public) and the
  `http_caller/1`/`mcp_caller/1` helpers, keeping only the allowed caller fields;
  moving them (`truncate/2` to `Guardian.Utils`, the caller helpers to a `Guardian.Web.Caller` module)
  is left for the removal of `query_parse_errors`
  (TODO.md `drop-query-parse-errors`). `Guardian.Web.Query.execute/3` takes an `:execute`
  option replacing `Guardian.Query.execute/2`, so tests can make the query path exit or
  throw.
- Docs: the built-in tables list in `docs/reference/api.md` (the README links to
  it); spec sections 2 (table of Guardian's tables), 3
  (query text kept for retention), 4.1/4.2 (queries recorded), 8 (fields); overview;
  `docs/architecture/system.md` 6.5 and the supervision tree; security.md (data at
  rest and B7, query text in `queries`); `lib/guardian/web/CLAUDE.md`, `lib/guardian/CLAUDE.md`.

## Product spec impact

- spec.md section 2: add `queries` to Guardian's tables.
- spec.md section 3.2: `queries` keeps the text of every HTTP and MCP query (up to 16
  KiB) for the retention period, not only failed ones; the sentence calling
  `query_parse_errors` "the only place Guardian keeps query text" changes to name
  both tables.
- spec.md 4.1 and 4.2: every query is recorded in `queries`; recording never changes
  the response.
- spec.md section 8: new item 5, `queries`, with the fields above.
- overview.md: list `queries` among the tables Guardian writes.

## Validation

- `test/guardian/web/query_log_test.exs`: over HTTP and MCP, a success, a query error (400), a
  statement-count rejection, a parse error and an internal error (ambiguous column)
  each write one row with the right outcome, kind, message and row count, and the
  response is unchanged; no key or header value reaches the row; a suspended
  recorder does not delay the response; a stopped recorder is logged and the query
  succeeds; querying `queries` writes one row per query; exits, throws and raises from
  the query path are reraised unchanged and recorded as `internal`; a failing caller
  function loses only the row; UTF-8-safe truncation of SQL and error; caller-field
  filtering and bounds; a failed write and a full backlog are counted in
  `dropped_before`, with one log line per backlog.
- `test/guardian/cluster/query_log_test.exs`: a query fanning out to a peer writes one row on
  the coordinator and none on the peer.
- `mix test` passes.

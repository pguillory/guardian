# Web Subsystem

Guardian exposes:

- JSON ingestion at `/api/json/send_events`
- JSON queries at `/api/json/query`
- MCP queries and ingestion at `/mcp`

Both routers authenticate only through `Web.Auth.check_conn/1`, which reads the first
`x-api-key` header and compares it with configured `:guardian, :api_key` in constant
time. The `api_key` query parameter is opt-in: only with `:guardian,
:allow_query_api_key` (`GUARDIAN_ALLOW_QUERY_API_KEY=true`, default off) is it read
when there is no header. With it off the query string is never decoded, so a request
without the header is `{:error, :missing}` whatever its query string. `check_conn/1`
returns `{:ok, :header | :query}` (where the valid key was found),
`{:error, :missing}`, `{:error, :unauthorized}`, or, with query keys on,
`{:error, {:invalid_query, status}}` when there is no header and the query string
cannot be decoded (status 400, or 414 over the length limit); each router keeps its
own error bodies (`test/web/auth_routes_test.exs` pins both). No identity is attached
to a request. The JSON API stores the method in the conn's private
`:guardian_auth_method`, and `Web.Logger` writes it to `web_requests` rows as
`auth_method` ("header" or "query"), never the key. MCP requests are not logged
there, so the MCP router calls `Web.Auth.note_query_key_use/1` on a query-parameter
key: one Logger line naming the path, at most once a minute per node.

`send_events` validates table, events list, and return_keys before storing anything.
HTTP invalid requests return 400 with an `info` message; MCP returns a tool error.
`Web.Ingest` shares request validation and result shaping between both interfaces.
Absent or null return_keys returns all event keys; a list of strings filters
successful events. Valid requests return
200 with ordered `results`, each `{success: true, event: ...}` or
`{success: false, error: ...}`. Events are independent: a failure does not stop the
rest, and uncertain storage failures say the event may have been stored.

JSON `/query` and the MCP `query` tool both run SQL through `Web.Query.execute/3`,
which wraps `Query.execute/2` (resolve, require one statement, label columns from the
pre-LET statement, run). Don't resolve or run queries in Web any other way. On an
`AST.ParseError` it has `Web.QueryParseErrors.record/4` record a `query_parse_errors`
row and the same error is reraised, so responses are unchanged.
Recording is a cast to the `Web.QueryParseErrors` GenServer: never make it
synchronous, because MCP tool calls run inside Anubis's shared server process and a
stalled Storage write would block every MCP request. Bounds (16 KiB SQL, 1 KiB error,
256-byte caller fields, 60 rows per machine per hour) are in that module.

`Web.Query.execute/3` also records every query, whatever its outcome, in the `queries`
table through `Web.QueryLog.record/4`, a cast to the `Web.QueryLog` GenServer under the
same never-synchronous rule. It catches raises, exits and throws and reraises them
with `:erlang.raise/3`, so callers see exactly what `Query.execute/2` produced; nothing
in recording may raise into the request. Keep recording in `Web.Query` (the
coordinating machine) so a distributed query is one row, and never record request
headers there (caller fields are `interface`, `remote_ip` and MCP client info).

The MCP server exposes `query` and `send_events` tools. Keep query results as a list
of maps while the JSON endpoint retains its `{columns, rows}` response shape.

# Web Subsystem

Guardian exposes:

- JSON ingestion at `/api/json/send_events`
- JSON queries at `/api/json/query`
- MCP queries and ingestion at `/mcp`

Both routers authenticate only through `Guardian.Web.Auth.check_conn/1`, which reads the first
`x-api-key` header and compares it with configured `:guardian, :api_key` in constant
time. The `api_key` query parameter is opt-in: only with `:guardian,
:allow_query_api_key` (`GUARDIAN_ALLOW_QUERY_API_KEY=true`, default off) is it read
when there is no header. With it off the query string is never decoded, so a request
without the header is `{:error, :missing}` whatever its query string. `check_conn/1`
returns `{:ok, :header | :query}` (where the valid key was found),
`{:error, :missing}`, `{:error, :unauthorized}`, or, with query keys on,
`{:error, {:invalid_query, status}}` when there is no header and the query string
cannot be decoded (status 400, or 414 over the length limit); each router keeps its
own error bodies (`test/guardian/web/auth_routes_test.exs` pins both). No identity is attached
to a request. The JSON API stores the method in the conn's private
`:guardian_auth_method`, and `Guardian.Web.Logger` writes it to `web_requests` rows as
`auth_method` ("header" or "query"), never the key. MCP requests are not logged
there, so the MCP router calls `Guardian.Web.Auth.note_query_key_use/1` on a query-parameter
key: one Logger line naming the path, at most once a minute per node.

`send_events` validates table, events list, and return_keys before storing anything.
HTTP invalid requests return 400 with an `info` message; MCP returns a tool error.
`Guardian.Web.Ingest` shares request validation and result shaping between both interfaces.
Absent or null return_keys returns all event keys; a list of strings gives successful
events exactly those keys, null for any the event lacks. Events are reported after
the table's SET/UNSET/TRACK/LOOKUP rules, so return_keys is how a client reads a
computed decision or counter result. Rule failure handling follows the
[product contract](../../../docs/product/spec.md#51-rules). Valid requests return
200 with ordered `results`, each `{success: true, event: ...}` or
`{success: false, error: ...}`. Events are independent: a failure does not stop the
rest, and uncertain storage failures say the event may have been stored.

Optional `idempotency_key` wraps Engine in `Guardian.Web.IngestIdempotency`.
The [public contract](../../../docs/product/spec.md#5-ingestion) (item 9) defines
matching, receipts, conflicts, capacity and protection limits;
[the API reference](../../../docs/reference/api.md#retrying-a-batch) shows client use.
The [ingest architecture](../../../docs/architecture/system.md#3-ingest-path)
describes claims, digests, monitors and expiry. Implementation rules to keep:

- Keep payloads and full replies out of coordinator state.
- Never expire or evict a live pending claim. Catch every ingestion failure to mark
  uncertainty before reraising, since callers can be reused HTTP processes or
  Anubis's long-lived MCP server.
- Bound coordinator calls to 100 ms. Cancel timed-out claims on the exact pid with
  their caller-generated token. Unavailable claims fail open with a fixed info log
  containing no client data; completion failures never hide the original response.

`IngestIdempotency.run/5` returns plain outcomes (`{:ran, value}`, `{:duplicate,
failed_events}`, `{:conflict, :changed | :pending | :uncertain}`) and treats the
ingest value as opaque; `Guardian.Web.Ingest` owns the receipt body, the 409 status
and the conflict messages.

JSON `/query` and the MCP `query` tool both run SQL through `Guardian.Web.Query.execute/3`,
which wraps `Guardian.Query.execute/2` (resolve, require one statement, label columns from the
pre-LET statement, run). Don't resolve or run queries in Web any other way. On an
`Guardian.AST.ParseError` it has `Guardian.Web.QueryParseErrors.record/4` record a `query_parse_errors`
row and the same error is reraised, so responses are unchanged.
Recording is a cast to the `Guardian.Web.QueryParseErrors` GenServer: never make it
synchronous, because MCP tool calls run inside Anubis's shared server process and a
stalled Storage write would block every MCP request. Bounds (16 KiB SQL, 1 KiB error,
256-byte caller fields, 60 rows per machine per hour) are in that module.

Keep application failures inside `Guardian.Web.JsonApi.call/2`, logging at most kind
and a generated ID; never restore Plug.ErrorHandler's raw reraising or print errors.
Pass Bandit transport/protocol errors through to its own cleanup and quiet logging.

`Guardian.Web.Query.execute/3` also records every query, whatever its outcome, in the `queries`
table through `Guardian.Web.QueryLog.record/4`, a cast to the `Guardian.Web.QueryLog` GenServer under the
same never-synchronous rule. It catches raises, exits and throws and reraises them
with `:erlang.raise/3`, so callers see exactly what `Guardian.Query.execute/2` produced; nothing
in recording may raise into the request. Keep recording in `Guardian.Web.Query` (the
coordinating machine) so a distributed query is one row, and never record request
headers there (caller fields are `interface`, `remote_ip` and MCP client info).

The MCP server exposes `query`, `send_events`, and the rule tools `list_rules`,
`read_rule`, `write_rule` and `delete_rule` (through `Guardian.Rules`). Keep query results as a list
of maps while the JSON endpoint retains its `{columns, rows}` response shape.

# MCP Server

Guardian's MCP endpoint exposes these tools:

- `query`: execute one resolved query and return rows as JSON objects keyed by labels.
- `send_events`: ingest a table and list of events through `Guardian.Web.Ingest` and Engine,
  returning `{status: 200, results: [...]}` with one ordered outcome per input.
  Optional return_keys filters successful events only; omitted/null returns all,
  an empty list returns no fields, and a selected key the event lacks is null.
  Failures do not stop later events, and uncertain storage failures say the event may
  have been stored.
  Optional idempotency_key shares HTTP's per-table/node receipt cache. Completed
  retries return `{status: 200, duplicate: true, failed_events: N}` without results;
  changed requests, pending claims and unknown outcomes are tool errors. MCP calls
  can queue/time out before this check because Anubis serializes them. Keep schema,
  tool description and `Guardian.Web.Ingest` validation consistent.
- `list_rules`, `read_rule`, `write_rule`, `delete_rule`: manage rule files through
  `Guardian.Rules`. A rejected or failed write is a tool error carrying the messages; a saved
  one returns `saved`, `remaining_errors` and `nodes_not_yet_reloaded`. The
  `write_rule` description summarizes the rule language; keep it in step with
  `docs/product/spec.md` section 5.1 and the served reference's Ingest rules section.
  TRACK/LOOKUP outputs use return_keys; completed keyed retries return only receipts.

The `query` description summarizes the language, its unsupported syntax, the untyped
data model, and the timestamp convention. The resource `guardian://query-language`
serves `query_language.md`, the full reference. When syntax, functions, or aggregates
change, update both. `Guardian.Web.MCP.QueryLanguageTest` fails when a registered function or
aggregate is missing from the reference or a `sql`/`gsql` example no longer parses. Server
`instructions` need Anubis 1.x or later.

Authentication is handled by `Guardian.Web.MCP.Router` before requests reach the Anubis server.
After authentication, the router answers 404 for an `mcp-session-id` that names no
live, initialize-handled session, as the Streamable HTTP spec requires, so clients
re-initialize after a restart or Anubis's 30-minute idle expiry. Anubis 0.16 would
otherwise create an uninitialized session and answer 200 "Server not initialized".
The check uses the internal `Anubis.Server.Registry` and `Anubis.Server.Session`;
recheck them when upgrading Anubis.

After the session check, the router answers GET with 405 (`Allow: POST, DELETE`): no
server-push stream. Anubis 0.16 sends request results down a registered GET stream and
answers the POST with 202, and never detects a stream the client dropped, so calls hung.
Without a stream every result comes back inline. Do not add server-initiated
notifications without revisiting this. Recheck when upgrading Anubis.

After the GET check, the router reads and decodes each POST body itself (8 MB limit,
413 above) and requires one JSON object that `Anubis.MCP.Message.validate_message/1`
accepts (it can raise; the router rescues that). Anything else gets 400 with a JSON-RPC
error (`-32700` undecodable, `-32600` otherwise). The decoded map is passed as
`body_params`, so Anubis skips its own decoding, which logs the whole body of a message
it cannot decode at error level. Log rejected bodies by size, reason, and a known
method name only; never log the body, its exception, or a caller-chosen method string.
Recheck on an Anubis upgrade.

`Guardian.Web.MCP.Server` registers its tools and resource on Anubis's frame before every
request, not in `init/2`. Anubis 0.16 keeps runtime-registered components in its one
shared frame's private map and empties that map when a DELETEd session it served last
ends, which left every other session with "Tool not found: query". The catch-all
`handle_request/2` clause calls `Anubis.Server.Handlers.handle/3`, Anubis's own default
dispatch (`super` is unavailable: Anubis appends its default at `@before_compile`).
Both are Anubis internals; recheck on an upgrade.

`send_events` validates requests explicitly before writes, returning MCP tool errors
with messages for invalid tables, events lists, return_keys or idempotency_key. Its advertised schema
is descriptive: runtime event items must reach Engine unchanged, including non-object
items which fail individually. Avoid typed Anubis validation that rejects mixed batches
or filters arbitrary event keys. Document table-name rules and stable object keys in
the tool description. Keep data in values rather than using data as object keys.

Do not add metadata tools. Preserve SELECT, SHOW TABLES, DESC,
query-time aggregations, and scalar function behavior.

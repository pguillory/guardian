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
  changed requests, pending claims and unknown outcomes are tool errors. A call can
  queue/time out before this check behind an earlier call in the same session. Keep
  schema, tool description and `Guardian.Web.Ingest` validation consistent.
- `list_rules`, `read_rule`, `write_rule`, `delete_rule`: manage rule files through
  `Guardian.Rules`. A rejected or failed write is a tool error carrying the messages; a saved
  one returns `saved`, `remaining_errors` and `nodes_not_yet_reloaded`. The
  `write_rule` description summarizes the rule language; keep it in step with
  [spec section 5.1](../../../../docs/product/spec.md#51-rules) and the served
  reference's Ingest rules section.
  TRACK/LOOKUP outputs use return_keys; completed keyed retries return only receipts.

The `query` description summarizes the language, its unsupported syntax, the untyped
data model, and the timestamp convention. The resource `guardian://query-language`
serves `query_language.md`, the full reference. When syntax, functions, or aggregates
change, update both. `Guardian.Web.MCP.QueryLanguageTest` fails when a registered function or
aggregate is missing from the reference or a `sql`/`gsql` example no longer parses.
Guardian sends no server `instructions` yet (TODO mcp-server-instructions).

Guardian runs Anubis 2.x (pinned exactly in mix.exs). Each MCP session is its own
process, and each request runs in its own task, so sessions never wait for each other;
requests within one session run one at a time. Wire behavior is pinned in
`test/guardian/web/mcp/` (`wire_test.exs`, `session_test.exs`, `body_test.exs`),
concurrency in `concurrency_test.exs`, and cancellation in `cancellation_test.exs`.
Anything below that names an Anubis internal must be rechecked on an Anubis upgrade,
and the wire compared before and after (status, headers and whole bodies).

The server offers only protocol version 2025-03-26 (`protocol_versions` on
`use Anubis.Server`): every initialize gets it back, as with 0.16. Later versions change
tools/list and result shapes, and 2026-07-28 is a stateless, handshake-free era, so
adding one is a wire change for clients.

Authentication is handled by `Guardian.Web.MCP.Router` before requests reach Anubis,
with `Guardian.Web.Auth.check_conn/2` and `:full` for every request: the insert-only
ingest key gets 403 `{"error": "this key can only send events"}`, checked before the
session lookup and body decoding, so a session ID never stands in for a full-access
key. The key is read only from the `x-api-key` header, and the router drops that
header once the key is checked: Anubis keeps request headers in its session frame and
in a failed call's log line. The router's other plugs, in order:

1. Unknown session: an `mcp-session-id` that names no live session gets 404
   `{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Session not found"}}`,
   as the Streamable HTTP spec requires, so clients re-initialize after a restart or
   Anubis's 30-minute idle expiry. Anubis answers 404 itself with a different body
   (-32600, a random id), and existing clients may look for -32001. The lookup uses
   `Anubis.Server.Registry.Local`, the registry Anubis uses for Streamable HTTP. Anubis
   2.x creates sessions only for initialize, so a live session is an initialized one.
2. GET gets 405 (`Allow: POST, DELETE`): no server-push stream, and every result comes
   back in its POST response. Anubis 0.16 sent results down a GET stream it never
   noticed had dropped, so calls hung; with 2.x a stream would only hold a connection
   open. Do not add server-initiated notifications without revisiting this.
3. Body: the router reads and decodes each POST body itself (8 MB limit, 413 above;
   Anubis reads without a limit) and requires one JSON object that
   `Anubis.MCP.Message.validate_message/1` accepts (it can raise; the router rescues
   that). Anything else gets 400 with a JSON-RPC error (`-32700` undecodable, `-32600`
   otherwise). The decoded map is passed as `body_params`, so Anubis skips its own
   decoding. Log rejected bodies by size, reason, and a known method name only; never
   log the body, its exception, or a caller-chosen method string.
4. Missing session: any POST other than initialize without a session ID gets the same
   404 -32001 (0.16 answered from a throwaway session, 2.x with its own 404 body).
5. The `MCP-Protocol-Version` header is dropped. Guardian serves one version, so the
   header carries nothing; Anubis 2.x would answer 400 to a version it does not serve,
   where 0.16 ignored it. Revisit if Guardian ever serves a second version.
6. Accept: when any Accept header allows `application/json`, the router replaces them
   with `application/json`, because Anubis 2.x answers an Accept that includes
   `text/event-stream` with an SSE-framed body, and existing clients may send both and
   parse the body as JSON.

`Guardian.Web.MCP.Server`:

- Registers its tools and resource on the session's frame before every request, not
  in `init/2`, which runs only on `notifications/initialized` while Anubis serves
  requests as soon as initialize completes. Registration replaces by name, and the
  returned frame is kept for the session's next request. (Defining them as compile-time
  components is TODO mcp-compile-time-components.)
- `server_tools/2` removes the `"$schema"` key Anubis 2.x adds to every inputSchema;
  Guardian's tools/list has never had it.
- The send_events schema writes options on a `{:oneof, ...}` type as
  `{:meta, type, opts}`, the form Anubis's field DSL builds
  (`Anubis.Server.Component.__build_field__/2`): Anubis 2.x turns
  `{{:oneof, ...}, description: ...}` into an empty schema.
- The catch-all `handle_request/2` clause calls `Anubis.Server.Handlers.handle/3`,
  Anubis's own default dispatch (`super` is unavailable: Anubis appends its default at
  `@before_compile`). An Anubis internal.

Cancellation: Anubis stops a request's task when the client sends
`notifications/cancelled` for it (the POST gets 200 with a "Request cancelled" error)
or deletes its session (200, -32603 "Session terminating"). A query stops with it
(`Guardian.Query` kills the query when its caller dies). `send_events` runs in
`Guardian.Detached`, so its batch always completes and its keyed receipt is completed
by the process that claimed it; rule writes run entirely inside
`Guardian.Rules.Server`, so they complete too. After a cancel or DELETE the session's
next request can run while that write finishes. An HTTP timeout stops nothing: the
request keeps running, and later requests in its session wait for it.

`Guardian.Web.MCP.LogFilter`: when a call times out or its session exits mid-call,
Anubis logs the call's exit reason at error, with the whole message and the request's
headers. The filter rewrites any Anubis line containing `{:mcp_request,` to name only
the exit reason. It depends on Anubis's formatted text; recheck on an upgrade
(`test/guardian/web/mcp/log_filter_test.exs` logs through Anubis's own macro).

`send_events` validates requests explicitly before writes, returning MCP tool errors
with messages for invalid tables, events lists, return_keys or idempotency_key. Its advertised schema
is descriptive: runtime event items must reach Engine unchanged, including non-object
items which fail individually. Avoid typed Anubis validation that rejects mixed batches
or filters arbitrary event keys. Document table-name rules and stable object keys in
the tool description. Keep data in values rather than using data as object keys.

Do not add metadata tools. Preserve SELECT, SHOW TABLES, DESC,
query-time aggregations, and scalar function behavior.

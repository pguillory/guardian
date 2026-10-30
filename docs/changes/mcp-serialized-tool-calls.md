# mcp-serialized-tool-calls: upgrade Anubis to 2.2 so MCP sessions run independently

## Problem

Anubis 0.16, Guardian's MCP library, ran every MCP request on a machine through one
server process. A slow `query` from any client made every other MCP caller on that
machine wait, for every method, `initialize` included. Anubis's 30-second request timer
started while a request was queued, so a long enough backlog timed requests out. A
client that reads through short MCP sessions, such as a monitoring check, could fail
because of someone else's slow ad-hoc query.

A probe with a GROUP BY that took 1.9 s alone measured two concurrent MCP calls on two
sessions finishing at 1.9 s and 3.9 s, while the same two queries called straight into
the query engine both finished at 2.5 s.

## Change

`anubis_mcp` moves from 0.16.0 to 2.2.0 (still an exact pin), and `peri` from 0.6.2 to
0.11.3 with it. In 2.x each MCP session is its own process and each request runs in its
own task. Sessions never wait for each other. Requests within one session still run one
at a time.

Guardian keeps what callers see the same as with 0.16. 2.x would otherwise have changed:

1. A POST whose Accept header includes `text/event-stream` would have been answered
   with an SSE-framed body. A client that sends `application/json, text/event-stream`
   and parses the body as JSON would have failed on every request. The router sets the Accept header to `application/json`
   whenever the client accepts JSON, so answers stay inline JSON.
2. The send_events `return_keys` and `idempotency_key` schemas would have lost their
   `oneOf` and `description`. They are written in the form 2.x's field DSL builds.
3. Every tool's inputSchema would have gained a `$schema` key. `server_tools/2` removes it.
4. A request whose `MCP-Protocol-Version` header names a version Guardian does not serve
   would have got 400. The router drops the header: Guardian serves only 2025-03-26.
5. Guardian pins protocol version 2025-03-26, the version 0.16 negotiated with every
   client. 2.2 would otherwise offer 2025-06-18, 2025-11-25 and the stateless 2026-07-28.

The router also keeps answering an unknown session with 404 and JSON-RPC code -32001
(Anubis's own 404 has code -32600 and a random id). It looks the session up in Anubis's
session registry, `Anubis.Server.Registry.Local`. The GET 405 and the router's body
decoding stay. Anubis no longer needs `Anubis.Server.Registry` started by Guardian: its
server supervisor starts its own registry, session supervisor and task supervisor.
Guardian starts it with `start: true`, so serving MCP never depends on Anubis's
Phoenix-environment heuristic.

`Guardian.Web.MCP.Server` still registers its tools and resource before every request,
now on the session's own frame: `init/2` runs only on `notifications/initialized`, and
2.x serves requests as soon as initialize completes. It still dispatches `send_events`
itself, so mixed batches reach Engine unchanged, and still calls Anubis's default
dispatch (`Anubis.Server.Handlers.handle/3`) for everything else.
`Guardian.Web.QueryParseErrors.mcp_caller/1` reads the caller's headers, IP and client
info from the frame's context. With a duplicated header it now records the last value
rather than the first (these fields are hints).

### Cancellation

In 0.16 a tool call always ran to completion: `notifications/cancelled` waited behind it
and DELETE did not reach it. In 2.x the client can stop a running request by cancelling
it or deleting its session. Anubis then kills the request's task. Decided behavior:

- A query stops: `Guardian.Query` already kills a query whose caller dies. Its
  `queries` row is not written, as for any killed request.
- `send_events` always completes. It runs in `Guardian.Detached`, a new leaf helper
  that runs a function in an unlinked process and waits for it, so a batch is never
  half-stored and a keyed receipt is completed by the process that claimed it. The
  worker is unsupervised, so a node shutdown can still stop it partway, as it could
  stop 0.16's server mid-call. Rule
  writes need no such helper: each runs entirely inside `Guardian.Rules.Server`.
- After a cancel or delete, the session's next request can run while that write
  finishes. A same-key retry during it gets the existing "in flight" conflict.

An HTTP timeout stops nothing, as before: the request keeps running, and later requests
in its session wait for it.

## Compatibility

A wire capture of about 60 exchanges (status, headers and whole bodies) through
`Guardian.Web.MainRouter` on 0.16 and on this change differs only in items 1 and 2
below; error IDs are random in both. The other items, all accepted, come from reading
the source and from the tests.

1. A POST other than `initialize` that names no session (a request, a ping, a
   notification, a response) gets 404 `{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Session not found"}}`.
   0.16 answered from a throwaway session: 200 "Server not initialized" for a request,
   200 for a ping, 202 for a notification.
2. Requests after `initialize` but before `notifications/initialized` are served. 0.16
   refused them with "Server not initialized".
3. A request that outlasts Anubis's 30-second timeout still gets HTTP 400 with code
   -32603, but `error.data` is `{"message": "Server unavailable"}` instead of
   `{"reason": "<json>"}`.
4. If a session's 30-minute idle expiry lands between the router's session check and
   Anubis's own lookup, the client gets Anubis's 404 body (-32600) instead of -32001.
   A POST to a session that is still shutting down gets 400 -32603 "Server
   unavailable" rather than 404.
5. A POST whose session is deleted mid-call gets 200 with -32603 "Session terminating"
   (with an inspected Elixir term in `error.data.reason`).
6. A cancelled call gets 200 with a "Request cancelled" error. For `send_events` and
   rule writes the write still completes.
7. An Accept header naming only `text/event-stream`, followed by a second Accept header
   naming `application/json`, is answered with JSON. 0.16 read only the first header
   and answered 406.
8. A crash inside `send_events` reaches the client as 200 -32603 "Tool execution
   crashed". In 0.16 it crashed the shared server process.
9. A `tools/call` whose params carry `task` (the 2025-11-25 tasks extension) gets
   -32601; 0.16 ignored the field. Guardian does not offer that extension.

Tool names, descriptions, order and schemas, the resource, query results and errors,
send_events results, the rule tools, parse and invalid-params errors, GET 405, DELETE
and unknown-session 404 are unchanged.

Logging: Anubis 2.x no longer logs whole incoming MCP messages at debug, or the bodies
of messages it cannot decode. Production stays at `:info`. Unchanged from 0.16: a
request that times out or whose session exits mid-call is logged at `:error` with the
call's whole exit reason, which includes the message and the request headers, the API
key among them. That is fixed separately (`docs/changes/mcp-log-redaction.md`).

## Product spec impact

`docs/product/spec.md`: section 4.2, section 5 item 9 and known limitation 2. The
overview is unchanged.

- New: Guardian speaks MCP protocol version 2025-03-26, answers every `initialize` with
  it and ignores the `MCP-Protocol-Version` header. This is existing behavior, now stated.
- Sessions: a POST other than `initialize` that names no session gets 404 too. Sessions
  are independent; requests in one session run one at a time.
- Instructions: the reason "the pinned MCP library version cannot" is dropped. Guardian
  still sends none.
- Timeout: "Meanwhile no other MCP tool call on that machine runs" becomes: the timeout
  does not stop the request, later requests in the same session wait, and other
  sessions are unaffected.
- New Cancellation paragraph: cancel or delete stops a query (a schema lookup on
  other machines may run on to its own timeout); writes complete.
- Idempotency: "because its tool server is shared" becomes queuing behind an earlier
  call in the session.
- Known limitation 2 is scoped to the same session.

## Validation

- `test/guardian/web/mcp/concurrency_test.exs` pins the fix. A test telemetry handler
  holds `query` calls from the test's sessions inside their request tasks. Two queries
  on two sessions are both in their tools at once, `initialize` on a new session (and a
  query on it) is answered while another session's query is held, and a second request
  on one session waits for the first. This pins 2.x's scheduler (0.16 emits no such
  event), with no wall-clock thresholds.
- `cancellation_test.exs`: suspending the table's mutable segment holds a running
  `DESC` query (its schema lookup runs inside the query process) or a `send_events`
  append. DELETE and cancel each kill the query process within a second, and another
  session still queries. While a cancelled `send_events` is held, its session answers
  a query and a same-key retry is told the first is still in flight. After DELETE or
  cancel, `send_events` stores its whole batch, and a same-key retry gets the
  duplicate receipt. These tests fail without
  `Guardian.Detached`.
- `wire_test.exs` pins:
  - A client that accepts JSON and SSE and parses JSON is answered inline as JSON
    through initialize, a query, an error and DELETE. This fails without the Accept
    fix.
  - Accept split over two headers.
  - The send_events schemas, and no `$schema`.
  - `MCP-Protocol-Version` ignored.
  - `initialize` answering 2025-03-26 to every version.
- `session_test.exs` moved off 0.16 internals and pins the session-less 404s.
- `test/guardian/detached_test.exs` covers the helper.
- The existing MCP, query log, parse error and rules tests pass unchanged apart from
  the test client, which 2.x builds without a macro.
- The full default suite runs in the pre-commit hook.

## Deploy notes

No configuration or secret changes. After the tech lead deploys from main, run only
read-only checks (no test events):

1. Every machine is healthy and runs the new release.
2. Wire checks:
   - `initialize` answers `protocolVersion` 2025-03-26.
   - `tools/list` has six tools, none with `$schema`, and send_events' `return_keys` and
     `idempotency_key` keep `oneOf` and `description`.
   - An unknown session and a session-less `tools/list` both get 404 -32001.
   - GET gets 405.
3. Live concurrency on one machine:
   - Pin one machine and open two sessions.
   - Time one read-only query alone that takes a few seconds, for example a
     `GROUP BY` over a large built-in table.
   - Run the same query on both sessions at once. Together they should take about as
     long as one, not two.
4. While step 3 runs, the deployment's other MCP clients and health checks should
   succeed within their usual budgets.
5. An interactive MCP client still lists tools and runs a query.

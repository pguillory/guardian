# mcp-log-redaction: keep MCP requests and the API key out of Anubis's failure log

## Problem

When an MCP request outlasts Anubis's 30-second call timeout, or its session exits
while the call waits, Anubis's Streamable HTTP transport logs the call's exit reason at
error (`session_call_failed`). Production logs at info, so the line is kept. The exit
reason holds the whole call, `{:mcp_request, message, context}`: the JSON-RPC message
(query SQL, events, rule source) and the request's headers, including `x-api-key`, the
admin key. Anubis 0.16 logged the same on its timeouts, which its single shared server
made more common. Anubis also keeps the request headers, key included, in each
session's frame, which a crash report could print.

## Change

1. `Guardian.Web.MCP.Router` drops every `x-api-key` header once the key check passes.
   Nothing after it reads the header, so Anubis never holds the key.
2. `Guardian.Web.MCP.LogFilter`, a `:logger` primary filter, rewrites any line logged by
   `Anubis.Logging` that contains a call (`{:mcp_request,`) to name only the exit
   reason: `MCP transport details: MCP call exited (timeout); request redacted`. The
   event line before it (`MCP transport event: session_call_failed`) is unchanged.
   `Guardian.Web` installs the filter before it starts Anubis. Anubis formats the
   reason into text before logging, so the filter matches that text; it is pinned by a
   test that logs through Anubis's own macro.

No wire change: callers get the same responses.

## Product spec impact

`docs/product/spec.md` section 3, the logging item: "Production logs at
info, so MCP messages (query text, event payloads) are not logged." gains ", including
when an MCP call times out or its session exits mid-call."

## Validation

`test/guardian/web/mcp/log_filter_test.exs`:

- A `session_call_failed` line for a real `timeout` and `noproc` exit of Anubis's
  session call, logged through `Anubis.Logging`, names the reason and contains neither
  the key, the header name nor the message. This fails without the filter. A real
  30-second timeout through HTTP is not exercised.
- Other Anubis lines and other loggers' lines pass unchanged.
- After a query, also with the key sent twice, the request's conn and the session's
  state hold no key. This fails without the router change.

## Deploy notes

No configuration change. After deploy, no new log line should contain `x-api-key`;
check by counting matches, never by printing lines. Lines from before the deploy may
contain the admin key if any MCP call timed out.

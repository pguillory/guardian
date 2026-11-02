# mcp-request-timeout: MCP calls outlast the query time limit

## Problem

Anubis, the MCP library, waits 30 seconds for a call by default, and Guardian did not
set it. A query may also run for 30 seconds, but its limit starts a little later,
after resolution. So a query that ran out its time almost always reached the client
as Anubis's generic timeout instead of the query's own "query exceeded its time limit
of 30 seconds; narrow it with WHERE or LIMIT", and Anubis logged the whole call at
error (`session_call_failed`). An error line means a problem to fix
(CONTRIBUTING.md, "Logging"); an ordinary slow query isn't one.

## Change

`Guardian.Web.MCP.Router` passes `request_timeout: 60_000` to
`Anubis.Server.Transport.StreamableHTTP.Plug`, whose `init/1` reads it and uses it for
each call's wait. (The option of the same name on the server's child spec does not
reach this wait.) 60 seconds covers the query's limit plus an ordinary resolution, so
a query that runs out its time answers with its own error and nothing is logged.

Anubis's timeout can still come first, and log the call, for a request queued behind
an earlier one in its session, a `SELECT *` whose schema lookup waits on a machine
that stopped answering (up to 60 seconds per table), or a slow `send_events`. Those
are documented and unchanged. A client's own timeout below 60 seconds now gives up
before Anubis does, where it used to see Anubis's error at 30.

Rejected: lowering the query limit below 30 seconds, which changes a documented
user-facing limit to work around a library default.

## Product spec impact

`docs/product/spec.md` section 4.2, the timeout paragraph. Before: "Timeout: the MCP
library gives each request 30 seconds (its default, which Guardian does not
override), and a query may run for 30 seconds ([section 7](#7-queries)). The two race:
the query starts a little after the request, so a query that runs out its time
usually reaches the client as the library's timeout error rather than the query's
time-limit error. Either way the query stops at its limit." After: "Timeout: the MCP
library gives each request 60 seconds, and a query may run for 30 seconds
([section 7](#7-queries)), so a query that runs out its time gets its own time-limit
error. The library's timeout can still come first for a request that waited behind an
earlier one in its session, or for a `SELECT *` whose schema lookup waits on a machine
that stopped answering (below). Either way the query stops at its limit."

Section 3, the logging item: "within the MCP library's 30-second timeout" becomes
"60-second", and the example "a query that runs out its 30 seconds" becomes "a query
queued behind another in its session".

## Validation

No automated test: showing it takes a call that outlives 30 seconds, and tests don't
wait out timeouts (CONTRIBUTING.md). A test comparing the setting with the query limit
would not show that the setting reaches the plug, which is what can go wrong. Checked by hand on a local node: a query that ran
out its 30-second limit over MCP (`RLIKE 'a*[^a]'` over 400 rows of 40,000 `a`s)
answered after 30 seconds with the query's time-limit error, and no
`session_call_failed` line was logged. With the router's setting removed, the same
query got HTTP 400 from Anubis at 30 seconds and the `session_call_failed` lines.

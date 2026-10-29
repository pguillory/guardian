# readme-walkthrough: the README as a three-part walkthrough

## Problem

The README listed Guardian's features and then toured the query language and rules
with unrelated examples (requests, logins). A reader had to assemble the main use
from the pieces: an application records events, an agent asks questions of them,
and rules return decisions the application acts on.

## Change

The README follows one small example, a web application that sends Guardian an
event for every request, through three short parts:

1. Putting events in Guardian: one `guardian.event("requests", {...})` call and the
   query an agent runs over MCP.
2. Getting decisions back: the application asks for `is_blocked` (`return_keys`) and
   refuses the request when it is set; the agent writes a rule that sets it.
3. Counters and rate limits: the agent adds a TRACK counter and folds it into the
   same rule. A field has one definition per table, so the rate limit joins the
   existing condition with OR rather than living in a second rule.

At the owner's direction the walkthrough uses the official Python client
(`Guardian(url, api_key=...)` and `guardian.event(table, fields, returning=[...])`),
and Connecting names clients for Python, TypeScript, Elixir and Rust. Those clients
are separate follow-up work (`clients` in TODO.md); until they ship, the README
describes them ahead of their release, and the plain HTTP request beside them works
today. Connecting also holds the MCP setup for Claude Code and Codex. Run it leads with
Fly.io (HTTPS at Fly's edge), then Docker on one's own machine. What Guardian isn't,
Elixir callers and the documentation index follow. The query-language tour is dropped
in favor of the reference.

## Product spec impact

None to the spec. The README describes the server's existing behavior, and the
official clients ahead of their release.

## Validation

Every walkthrough sample was run against a local Guardian started from this change's
tree (`mix run --no-halt` with scratch keys on a non-default port, data under the
ignored `data/dev`), never a deployment: the `guardian.event` calls, the query and its rows, and both rule sets,
written through MCP `write_rule`. The calls were made with a ten-line stand-in
for the client's `event` function over `requests` 2.32; the client itself does not
exist yet. Before any rule `is_blocked` came back null; with
the first rule it was true for the listed IP and false for another; with the counter,
one IP's 100th request returned `requests_last_10m` 100 and not blocked, its 101st
101 and blocked. The Fly and Docker commands are carried over from the Fly guide and
the previous README and were not rerun (no deploys). The repository's checks ran
before commit.

# Logging

Status: in progress.

Product spec impact: step 1 changes nothing. Step 2 replaces spec.md section 3.1's
promises about query text in logs (item 2): before, "These are meant to be the only
places Guardian keeps query text. Application failures caught inside the JSON API log
at most their kind and a server-generated error ID, without printing query text,
exception messages, or stack traces. Failures outside that boundary and OTP crash
reports retain the logging limits described in the security architecture. Production
logs at info, so MCP messages (query text, event payloads) are not logged, including
when an MCP call times out or its session exits mid-call." After: "These are the only
tables that keep query text, but logs are not scrubbed. Production logs at info, so a
request that succeeds within the MCP library's 30-second timeout logs no MCP message,
query text or event, apart from the warnings described in the security architecture.
An MCP call that outlives that timeout, or whose session exits mid-call, logs its
message at error, even if the call later succeeds (for example a query that runs out
its 30 seconds, or a slow `send_events` with its event values). An error line or crash
report can show what the failing process held: query text, event values (before rules
unset them), rule text or counter keys. Each router drops the request's API keys once
they pass, so no plug or handler after that check receives them."

## Problem

A passing `mix test` printed hundreds of lines: a `Loading` line per segment file and
an `Expiring` line per expired segment through `IO.puts`, `make: Nothing to be done for
'nifs'` on every compile, Anubis client errors, and crash reports from tests that break
things on purpose. Production printed the same per-segment lines on every boot.

## Rules

CONTRIBUTING.md's "Logging" section, Preston's decision: text logs cover lifecycle
(starting up, loaded, listening, shutting down, stopped), nothing per event, segment or
request; an error-level line is a bug or problem to fix; logs get clean by fixing
errors, never by hiding them; logs are not scrubbed, except that each router drops the
API key once it passes; everything goes through Logger.

## Changes

1. Lifecycle through Logger. Guardian logs "Guardian: starting build …", "Guardian:
   stopping" and "Guardian: stopped" at info. Storage's initial load logs "Storage:
   loading N segment files" before it starts, since a large data directory can take a
   while, and "Storage: loaded N segments (M skipped)" when done; the per-file `Loading`
   line goes, and rescans log only files they skip. The startup notice about `.seg`
   files with unparseable names becomes a Logger warning, still once per start. The
   per-segment `Expiring` line goes with no replacement, so expiry leaves no text trace.
   Bandit's own startup line says the web server is listening. The `nifs` make target
   gets an empty recipe, so an up-to-date build prints nothing.

2. Stop scrubbing. The `format_status/1` callbacks that redacted Rules.Server's,
   Counters.Store's, Budget's, Restarter's and IngestIdempotency's state go, with their
   tests, so `:sys.get_status/1` and crash reports show the real state.
   `Guardian.Web.MCP.LogFilter` goes: Anubis's `session_call_failed` line, logged when
   an MCP call outlives its 30-second timeout or its session exits mid-call, now shows
   the message (as `inspect/1` prints it, so very long values are cut short). The API
   key never reaches it: both routers drop the header once the key passes. Query heap limits stop writing the VM's kill report
   (`error_logger: false`, like the rule worker and the regex helper): an over-limit
   query is the caller's outcome, answered with the heap message. The catches that
   reraised failures by kind (Rules.Server's and Store's `scrubbed`) went in a
   separate change (f45a43a).

## Validation

`mix compile` on an up-to-date build prints nothing; the storage suite passes without
the per-segment lines.

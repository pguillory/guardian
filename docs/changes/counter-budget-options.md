# Counter budget tests use per-event options

Status: implemented.

Product spec impact: none. No statements change in overview.md or spec.md. Production
counter budgets, caps, cooldowns and results are unchanged, and no `lib/` behavior
changes.

Wire impact: none. Nothing that crosses nodes changes.

## Problem

Part 2 of test isolation. Tests raise counter budgets in two overlapping ways:
`Guardian.Test.Counters.Budget.relax/1` and `scale/1` set node-wide application env,
which forces `async: false`, while Context's `:timeout_ms` and `:event_timeout_ms`
options (`docs/changes/counter-client-fanout.md`) replace the budgets for one event.
Tests that build their own Context have no need for the node-wide setting.

## Change

1. Tests that build their own Context on local owners pass options instead of calling
   `relax/1` or `scale/1`. `Guardian.Test.Counters.Budget` gains the scaled counterpart
   of `relaxed_options/0`, and batch helpers sized in those scaled units.
2. `client_test.exs` splits by what it needs. Tests with local owners and no VM-wide
   process scan stay in `Guardian.Counters.ClientTest` and go `async: true`. Tests that
   start or call peers, or that scan `Process.list/0` for Transport helpers, move to a
   new `async: false` `Guardian.Counters.ClientPeerTest`. Each module has its own
   cooldown table name.
3. `context_test.exs` goes `async: true`. The test of the application-env seam moves to
   a small `async: false` `Guardian.Counters.ContextSeamTest`.
4. `budget_test.exs` goes `async: true`. Its setup gives the event a long event budget,
   so reservations stay exactly one 50 ms call however long the test waits to reserve;
   the call budget, the only value its assertions use, keeps its production default.
   The 250 ms `Task.yield` that proves no call waits on the suspended cooldown owner
   becomes 5 s, since only a hang fails it.
5. `counter_rules_test.exs` stops relaxing: `event/2` passes `relaxed_options/0`, and
   `Guardian.Test.Counters.relaxed_store/1` goes away. The module stays `async: false`
   for the shared rule store, application env and log capture.
6. Local tests that move to async pass larger budgets where load could change their
   result: a healthy recovery call passes relaxed options, and calls about the call
   budget or the allowance pass a long event budget, so a late start cannot trim their
   reservation.

## What keeps the seam

The application-env seam, `relax/1` and `scale/1` stay, because two kinds of test have
no other way to get a larger budget.

1. End-to-end ingestion: `counter_ingest_test`, `counter_reload_test`, `rules_tools_test`
   and `server_test` ingest through Engine, HTTP or MCP. Runner calls `Event.start/2`
   with no options and neither Engine, the HTTP route nor the MCP tool takes any, so
   there is no per-call path. Adding one to Engine and Runner would be a new production
   path for tests, and could not reach HTTP or MCP at all. Dropping the relaxation would
   bring back the load failures in `docs/changes/counter-test-budgets.md`.
2. Peer owners: a peer's `Transport.remote_operation/3` refuses a duration above its own
   `Context.operation_ms()`, so a larger per-event budget comes back as
   `{:error, :invalid_request}`. These tests stay sync anyway.

Removing the seam therefore needs a decision outside this change; see Follow-ups.

The end-to-end modules are `async: false` anyway, for the shared rule store and
Rules.Server restarts, so keeping the seam there costs no concurrency, only code.

## Follow-ups

Seam removal, for the maintainer to decide. Removing `relax/1` and `scale/1` takes one answer
for each kind of test above, and each answer has a cost this change does not take on
its own authority:

1. Peer owners, with no wire change: `duration_ms` already crosses the wire and is the
   per-call bound. Replace the check against `Context.operation_ms()` with a fixed
   ceiling, for example the 1 s row limit. Production callers never send more than 50 ms,
   so healthy traffic and mixed-version nodes are unaffected, but the endpoint's
   defense-in-depth loosens from 50 ms to the ceiling.
2. End-to-end ingestion, one of:
   1. Run those tests at production budgets, accepting flakes under load.
   2. Thread Context options through Engine and Runner (a new production path), with the
      HTTP and MCP tests still at production budgets.
   3. Set the defaults at compile time in the test build, like Transport's
      `store_backend`. This removes all runtime env and covers HTTP, MCP and peers, but
      the test build's defaults would no longer be production's, and every budget test
      must then pass production's values explicitly. Nothing could then test the remote
      endpoint's production bound, since `remote_operation/3` takes no Context options.

Considered and rejected: a test publishing a wrapper rule module that rebuilds
`event.counters` with larger budgets. It adds no production path, but it cannot cover
rules written through Rules.Server, MCP or HTTP, and it weakens the end-to-end fidelity
those tests exist for.

## Validation

The affected files passed under six seeds on a quiet machine. The pre-commit hook's
full suite runs them alongside the other async modules.

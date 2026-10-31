# Remove the counter budget and cooldown

Status: implemented.

Product spec impact: `docs/product/spec.md` 5.1.4 item 6 is replaced. Calls still wait
at most 50 ms. The 100 ms counter phase per event, the 250 ms failed-call allowance per
batch and the one-second owner cooldown are gone, and the item now says that nothing but
each row's rule time limit bounds counter waiting.

Wire impact: `Transport.remote_operation/3` keeps its arguments and replies. It no
longer refuses durations above 50 ms, and callers send at most 50 ms. Rolling deploys
across this change keep working.

## Problem

Failed-wait reservations, refunds, settlement, event deadlines and cooldown ETS were a
lot of machinery for one case, a connected peer that stalls without dying, on a system
that puts simplicity ahead of consistency. On one machine they do nothing useful: the
owner is local and Store is direct ETS. There, one slow call under load cooled the local
store down and defaulted every count for a second.

## Change

1. `Guardian.Counters.Budget` is deleted. The counter supervisor runs Store alone, and
   `counters_available` checks the supervisor and Store.
2. `Context` holds the call timeout, members and store. `Transport.dispatch/2` starts
   every owner's pipeline at once, each with its own deadline, and waits for them. The
   guard and worker stay: they bound a call that distribution flow control blocks.
3. Runner and Event no longer carry a batch handle.
4. The application-env budget seam and `Guardian.Test.Counters.Budget` are deleted. The
   test build sets a 500 ms call timeout at compile time in `config/config.exs`, as
   follow-up 2.3 of `docs/changes/counter-budget-options.md` described: tests that ingest
   through Engine, HTTP or MCP have no per-call path, and a slow healthy call at 50 ms
   would silently give a default count. It stays under Runner's 1 s row limit, so a
   timed-out call at one level in a test still fails open. No test exercises production's 50 ms.
5. Without node-wide budgets, `rules/counter_ingest_test` is async, and its peer test
   moved to `rules/counter_ingest_cluster_test`.

## Cost

With a stalled, connected peer, each event needing it waits about 50 ms per dependency
level, with no cap across a request: about 50 ms times levels times rows until the VM
declares the peer down, minutes on a large batch. An owner answering just under
50 ms keeps machines alive through later rounds, about 300 ms a level, so a row with
several levels can reach Runner's 1 s row limit and be refused, where the old 100 ms
event phase would have defaulted and stored it. This only applies with several machines. See counter-peer-wait-bound in TODO.md.

## Validation

`mix test --include cluster --include lifecycle` passed. A store double that never
answers gives `{:error, :timeout}` at the Client layer, Execution's scripted-error tests
cover the fail-open defaults, and a connected peer with no store gives the missing result
through real ingest. Nothing here ran against a deployment.

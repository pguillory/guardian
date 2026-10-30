# Client owns counter fan-out

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. TRACK/LOOKUP results, fail-open defaults, rounds, owner
pipelines, deadlines and budgets are unchanged.

## Problem

`Guardian.Counters.Execution` knows how operations are distributed across the
cluster: each round it routes operations (`Client.route/2`), groups them by owner,
sends the owner batches (`Client.dispatch/2`) and scatters the responses back. The
round loop needs none of that. A machine holds a pending operation and takes a
response, and a CAS retry is just that machine's next operation in the next round.

`run_counters` and `run_state_machines` also take a `dispatch` function parameter
that exists only so tests can script responses. Function-parameter injection isn't
how Guardian makes test seams; the existing pattern is module-level, like Transport's
compile-time `store_backend`. Tests can use the real Client against
`Guardian.Test.Counters.ProbeStore`, so no fake is needed.

Moving the tests to the real Client brings real budgets into them. Their healthy calls
need budgets larger than production's 50 and 100 ms under host load, but the only way
to raise them today is the node-wide `Guardian.Test.Counters.Budget.relax/1`, which
forces `async: false`.

## Change

1. `Client.batch(operations, context)` takes one list of operations and returns one
   response per operation, in the same order. It routes each operation, groups the
   routed ones by owner (`Lists.group/1`, still the one place that orders a round's
   owners), runs the owner pipelines through `Transport.dispatch/2`, and puts the
   responses back with `Lists.ungroup/2` and `Lists.unfilter/3`. A malformed
   operation's routing error is its response. Bad membership still raises.
2. `Client.route/2` and `Client.dispatch/2` leave Client. Transport keeps `route/2`
   and `dispatch/2` as its internals, unchanged.
3. Execution's `run_one_iteration` becomes: collect each machine's pending operation,
   call `Client.batch/2`, advance each machine with its response. Routing, grouping
   and the `dispatch` parameter are gone: `run_counters/3`, `run_state_machines/2`.
   `run_counters` still catches a raised round.
4. Context's `:timeout_ms` and `:event_timeout_ms` options replace the default instead
   of being capped by it, so a test passes larger budgets per event, with no node-wide
   setting. No production code passes these options. The application-env seam stays:
   it still sets the defaults and the remote endpoint's bound, so tests with remote
   owners keep using it and stay `async: false`.
5. `Guardian.Test.Counters.Budget.relaxed_options/0` returns those per-event budgets
   (900 ms event, 1 s operation, the same values as `relax/1`).

This supersedes the part of `docs/changes/counter-execution-topdown.md` that replaced
an earlier `Client.batch/2` with route and dispatch and added the `dispatch` parameter.
That change's stated problem was the id-keyed map and positional ids, and neither comes
back: this call is list in, list out, through `Guardian.Lists`.

## Behavior kept

The same rounds, one owner pipeline per round, owners started in sorted order (which
decides who gets a reservation when allowance is short), one failing owner erroring
only its own operations, no budget touched by an empty or all-malformed round, and a
raised round failing the level open. The round barrier stays: a slow owner still holds
the next round for every owner. The remote endpoint doesn't change.

## Tests

`execution_store_test.exs` folds into `execution_test.exs`, one async module using a
private Store, a private Budget cooldown table (`Guardian.Test.Counters.private_store/1`)
and `relaxed_options/0`:

- The scripted cases run on ProbeStore through the real Client. Its `{:pipeline, fun}`
  mode sees whole batches, so round composition stays asserted.
- Dropped: the duplicate CAS-attempts case (the store test's case stays; the callback
  exception half of the scripted test stays), the `:peer@host` interleaving test and
  the malformed-reply `short` test.
- Kept, through the real Client: a raised round gives `{:error, kind}` per op while an
  expansion failure keeps its own kind, now triggered with `members: []`.
- A per-operation `{:error, :timeout}` can set a cooldown when the reservation is at
  least 25 ms, so cases that continue after one pass a shorter `timeout_ms`.

`client_test.exs` uses `Client.batch/2` directly, and its helper stops going up through
`Execution.run_state_machines`:

- "owner pipelines run concurrently" takes an interleaved list with a malformed
  operation in the middle and answers each owner differently (distinct buckets), so a
  swap between owners or a misplaced routing error fails. It previously used a map, so
  its owners arrived contiguous, and both owners returned the same bucket values.
- The "input order above 32 operations" test moves here, since grouping lives here.
- "pending healthy owners" gets its owners in reverse order, so it pins Client's sort.
  The dropped interleaving test was the only one with owners out of order.

`context_test.exs` pins the new option behavior, and `runtime_test.exs`'s one
`Client.dispatch/2` call becomes `Client.batch/2`.

## Docs

`lib/guardian/counters/AGENTS.md`, `lib/guardian/AGENTS.md`,
`lib/guardian/rules/AGENTS.md` (arity), `docs/architecture/system.md`, the
`libtest/guardian/test/counters.ex` and `budget.ex` moduledocs, a superseded note in
`docs/changes/counter-execution-topdown.md`, and TODO.md.

## Deploy

No wire or storage change: `remote_operation` is untouched.

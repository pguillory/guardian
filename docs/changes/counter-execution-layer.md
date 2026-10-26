# Counter execution in the counters layer

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Counter results, defaults, rounds, owner pipelines and
order are unchanged.

## Problem

`docs/changes/counter-execution-topdown.md` made counter execution read top-down
in `Guardian.Rules.CounterRuntime`: `run_counters/3`, the round loop
(`run_state_machines/3`, `run_one_iteration`), routing, grouping, scatter, bucket
expansion and combination. That put a generic mechanism, the round loop over key
machines, inside the Rules feature, and left the order of a round's owners as an
implicit contract between Rules (which sorted them through `Guardian.Lists.group/1`)
and Counters (whose dispatch starts owners in the order given). The earlier
document kept the module in Rules partly because bucket expansion read as Rules
semantics; bucket windows, expiries and combination are counter storage design,
so they move down with the round loop.

## Shape

- Rules, above: `Guardian.Rules.Runtime` prepares each counter statement as
  skipped, failed or an op, runs a level's ops through
  `Guardian.Counters.Execution.run_counters/3`, writes each result into its event
  field and logs `{:error, kind}` results by file and line.
- Counters, below: `Guardian.Counters.Execution` is the former CounterRuntime,
  moved whole and otherwise unchanged: run_counters, run_state_machines,
  run_one_iteration, routing/grouping/scatter, bucket expansion, combination and
  `missing/1`. `run_state_machines/3` gains the same default dispatch
  (`Client.dispatch/2`) as `run_counters/3`.
- Owner order: Execution is documented as the one place that orders a round's
  owners (ascending, through `Lists.group/1`, with each owner's operations in
  input order); Client and Transport dispatch in the order given. No assertion
  is added in Transport: its one production caller is beside it, and Execution's
  tests pin sorted owners and input order above 32 operations.
- Name: "Execution", because the docs call it counter execution;
  `Counters.Runtime` would collide with `test/guardian/counters/runtime_test.exs`.

Known coupling, left for a follow-up: ops carry `Guardian.Rules.CounterDefinition`s
and the event is a `Guardian.Rules.Event`, so Execution reads Rules structs' counter
fields (identity, operator, window and bucket sizes; arrival coordinates and the
counter context) and names them in typespecs. It never pattern-matches them, so
there is no compile-time struct dependency. Moving the counter definition and the
arrival coordinates into Counters is TODO `counter-definition-layer`.

## Tests

- `test/guardian/rules/counter_rounds_test.exs` moves to
  `test/guardian/counters/execution_test.exs` (`Guardian.Counters.ExecutionTest`),
  assertions unchanged.
- `test/guardian/rules/counter_runtime_test.exs` keeps its name (its subject is
  Rules' counter behavior through Runtime and compiled modules, and change docs
  cite it); its helpers call Execution.
- `test/guardian/counters/client_test.exs` drops its helper that re-implemented
  route/group/dispatch/scatter: each operation becomes a one-shot machine that
  finishes with its response, run through `Execution.run_state_machines/2`. A nil
  operation reads as an already-finished machine (`Machine.done?` is
  `op == nil`), so the malformed-operation test asserts `Client.route(nil, _)`
  directly; key machines never hold a nil operation, so production is unaffected.

## Docs

`lib/guardian/counters/CLAUDE.md`, `lib/guardian/rules/CLAUDE.md`,
`lib/guardian/CLAUDE.md`, `docs/architecture/system.md` section 3.5, the
superseded placement note in `docs/changes/counter-execution-topdown.md`, and
TODO.md.

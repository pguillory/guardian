# Counter definition and arrival in the counters layer

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Counter results, identities, keys, buckets, expiries,
defaults and plan hashes are unchanged.

## Problem

`docs/changes/counter-execution-layer.md` moved counter execution into
`Guardian.Counters.Execution`, but its inputs were still Rules types: ops carried
`Guardian.Rules.CounterDefinition`s and `run_counters/3` took a `Guardian.Rules.Event`
for the arrival coordinates and the counter context. A lower layer should depend on
nothing above it.

## Shape

- `Guardian.Counters.Definition`: the former CounterDefinition struct, same fields
  (identity, operator, window_ms, bucket_ms, group_arity). `new/4` takes the
  identity, operator, window and grouping arity and sizes the buckets (three per
  window, rounded up; a nil window, which Rules validation reports, has a nil
  bucket). `aggregation/1` fetches the operator's shared aggregation.
- Rules keeps what comes from rule text: `Guardian.Rules.Step` builds a TRACK's
  definition (identity from table, field and the source's SHA-256; the LAST interval
  in milliseconds with its 365-day bound), and Validation, Resolution, Activation and
  Runtime use the counters struct.
- `Guardian.Counters.Arrival`: the private arrival coordinates, `unix_ms` (formerly
  `arrival_ms`) and `monotonic_ms`, captured by `now/0`. Engine and Runner capture it;
  `Guardian.Rules.Event` is now `%Event{arrival: Arrival, counters: Context}`, both
  always set (the former "Event without counters" pre-start value is the Arrival).
- `Execution.run_counters(ops, arrival, context, dispatch \\ &Client.dispatch/2)`.
  Runtime passes `event.arrival` and `event.counters`. Nothing under
  `lib/guardian/counters/` references a Rules module in code.
- `Execution.missing/1` is removed rather than moved into Aggregation:
  `Guardian.Aggregation.default/1` already is the missing result, and the rest was
  the operator lookup, now `Definition.aggregation/1`. Runtime writes
  `Aggregation.default(Definition.aggregation(definition))`. An Aggregation function
  taking a counter definition would make the shared registry know about counters.

## Plan hashes

A resolved plan's hash folds in each LOOKUP target's hash term, which included the
definition's struct name. `Guardian.Rules.Resolution.hash_term/1` now owns that term
and keeps `__struct__: Guardian.Rules.CounterDefinition` as a frozen format tag, so
every dependent hash, and the pinned baselines in `counter_plan_test.exs`, stay the
same ("metadata refactors must not reset dependent hashes",
`docs/changes/plan-hash-determinism.md`). The tag is not a module reference; renaming
it resets dependent hashes. The plan test checks that the hash term covers exactly
the definition's fields under that tag.

Compiled rule modules embed the definition structs, so this change, like every
Guardian release, needs a full restart; it cannot be hot-loaded into a VM running
plans compiled with the old struct.

## Tests

- `test/guardian/rules/counter_runtime_test.exs` (named after the removed
  `Rules.CounterRuntime`) splits. Its tests that drive `Execution.run_counters`
  directly (bucket boundaries, expired arrivals, skipped writes, chronological
  merging, CAS attempts and retries, failed buckets, TTLs, budget refunds,
  concurrency) move into `test/guardian/counters/execution_test.exs`, under
  "against a store", with definitions from `Definition.new/4` and arrivals from
  `Arrival.now/0` instead of rule plans; assertions unchanged. ExecutionTest becomes
  `async: false` for the shared budget seam. The rest (Runtime, compiled modules,
  Runner, Engine) is `test/guardian/rules/counter_rules_test.exs`.
- The shared scripted store moves to `Guardian.Test.Counters.ProbeStore` in libtest.
- The `Rules.Event.start/3` test moves from the counters ContextTest to
  `test/guardian/rules/event_test.exs`, so counters tests reference no Rules module.

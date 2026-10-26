# Test support consolidation

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Test code only: production modules are unchanged; the one
non-test edit is the test-only counter backend name in `config/config.exs`'s test
block. Test scenarios, assertions and coverage stay the same, apart from one test
that now captures and asserts the warning it already logged.

## Problem

1. `Guardian.Counters.ExecutionTest` is one serial module holding two kinds of tests:
   pure round-loop tests against a scripted dispatch function (no store, no
   node-wide state) and store-backed tests that relax node-wide counter budgets. The
   round-loop tests run serially only because they share the module.
2. ExecutionTest and `Guardian.Rules.CounterRulesTest` each copy the same setup:
   relax budgets, start an unnamed Store and a named cooldown table, and build event
   options (`store: ProbeStore.backend(store), members: [node()], cooldown_table:`).
3. Two test modules know the Store's private descriptor (the
   `:counter_store_descriptor` process-dictionary key and ETS row):
   `Guardian.Test.Counters.ProbeStore.backend/1` (to tell a real Store from a probe)
   and `Guardian.CounterStoreProbe` (to pause a real Store). The counter probes and
   backend (`CounterStoreProbe`, `CounterPipelineProbe`, `CounterTestBackend`) are
   still outside `Guardian.Test.*`, as are some other specialized helpers.
4. CounterRulesTest's top-N test logs an uncaptured
   `Rule ... failed: Guardian.Query.Error` warning into the suite output.

## Changes

### Counter probe family under `Guardian.Test.Counters`

| Previous module | Current module | Role |
| --- | --- | --- |
| `Guardian.CounterTestBackend` | `Guardian.Test.Counters.Backend` | The test build's Transport `store_backend`: routes `{module, server}` to `module.batch/2`, anything else to the real Store |
| `Guardian.CounterStoreProbe.batch/2` | `Guardian.Test.Counters.ProbeStore.batch/2` | Mailbox batch adapter for any probe process speaking `{:operation, deadline, {:batch, ops}}` |
| `Guardian.CounterStoreProbe.pause/1`, `resume/1` | `Guardian.Test.Counters.StorePause` | Gate a real Store's callers through its clock; the one place that reads or replaces a real Store's descriptor, with `store?/1` answering whether a process is a real Store |
| `Guardian.CounterPipelineProbe` | `Guardian.Test.Counters.PipelineProbe` | Named probe that reports and holds each pipeline until released |

`ProbeStore.backend/1` then returns `{Guardian.Test.Counters.ProbeStore, pid}` for
probes, and callers that built `{Guardian.CounterStoreProbe, x}` by hand use
`{Guardian.Test.Counters.ProbeStore, x}`. Function bodies, timeouts and replies are
otherwise unchanged. `Guardian.Test.Counters.Client.preload/0` loads the new modules
on peers, and the config's test block names the new backend.

### Shared relaxed-store setup: `Guardian.Test.Counters`

A small module at `libtest/guardian/test/counters.ex`:

1. `relaxed_store(cooldown_table)`: relaxes budgets for the calling test, starts an
   unnamed Store and a Budget cooldown table under the test supervisor, returns
   `%{store: store}`. Serial tests only (it relaxes node-wide budgets), documented.
2. `event_options(store, cooldown_table, opts \\ [])`: the shared Context options,
   merged with `opts`.

ExecutionTest's store tests and CounterRulesTest call these; each keeps its thin
local `event` wrapper (one builds a Counters context, the other a `Rules.Event`).

### ExecutionTest split

1. `Guardian.Counters.ExecutionTest` (`async: true`): the seven round-loop and level
   result tests against scripted dispatch, unchanged.
2. `Guardian.Counters.ExecutionStoreTest`
   (`test/guardian/counters/execution_store_test.exs`, `async: false`): the
   `against a store` tests, unchanged apart from the shared setup.

Same test count and assertions; the CounterRulesTest moduledoc pointer names both.

### Remaining specialized helpers, where cheap

| Previous module | Current module |
| --- | --- |
| `Guardian.FakeS3` | `Guardian.Test.FakeS3` |
| `Guardian.JsonApiTestClient` | `Guardian.Test.JsonApiClient` |
| `Guardian.MCPTestClient` | `Guardian.Test.MCPClient` |
| `Guardian.DistributedStreamTestStages` | `Guardian.Test.DistributedStreamStages` |
| `Guardian.EngineTestKey` | `Guardian.Test.EngineKey` |

Each moves to the matching path under `libtest/guardian/test/`, with references in
tests, subsystem CLAUDE.md files and `docs/architecture/system.md` updated.

Not moved, because they are not cheap:

1. `Guardian.Query.EvaluationTestCase`: used by about 100 function, operator and
   aggregation test files and the query-functions guide; it mirrors its subject's
   namespace and is the documented entry point for function authors.
2. `Guardian.Query.Function.TestRaise`: the production function registry names it
   in its test-build branch, so renaming it edits `lib/`, and it belongs beside the
   functions it imitates.

### Captured warning

Only the top-N test's cross-bucket combination failure logs; a failed in-bucket
merge defaults quietly. The test wraps that one run in `capture_log` and asserts the
captured log names `Guardian.Query.Error`.

## Docs

`docs/architecture/system.md`'s testing section and the subsystem CLAUDE.md files
name the new modules; `docs/changes/test-support-namespace.md` gets a note that this
change moved the helpers it left in place. Historical change documents keep the
names they used. TODO.md records the change.

## Validation

The plan passed independent Claude and Codex review. Claude's review suggested
folding the planned separate descriptor module into `StorePause` (done) and
noticed that only the third top-N run logs (confirmed by running it).

1. Test compilation passes with warnings as errors, and no old module name remains
   outside historical change docs.
2. Focused runs of every touched test file, including ClientTest's peer pipeline
   probes and StoreTest's pause: 303 tests, no failures. ExecutionTest (7 tests) and
   ExecutionStoreTest (13) hold the original module's 20 tests.
3. Independent Claude and Codex code reviews approved, each with five concern
   helpers. Both flagged the new helper's `Budget` alias shadowing the production
   module (now `CounterBudgetHelper`); Claude's tidy-ups rewrapped a system.md line,
   clarified the helper's moduledoc and dropped private queue names from this doc.

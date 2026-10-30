# Common test support namespace

Status: implemented and validated.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. This is a structural refactor of test infrastructure;
production behavior, test scenarios, assertions and coverage stay the same. The
source-scan test's helper path follows its move, retaining the same assertion.

## Names and responsibilities

Shared helpers live under `Guardian.Test.*`, at matching paths in
`libtest/guardian/test/`, with one module per file and no compatibility wrappers.

| Previous module | Current module |
| --- | --- |
| `Guardian.TestEnv` | `Guardian.Test.Env` |
| `Guardian.TestCluster` | `Guardian.Test.Cluster` |
| `Guardian.CounterClientHelper` | `Guardian.Test.Counters.Client` |
| `Guardian.CounterBudgetHelper` | `Guardian.Test.Counters.Budget` |
| `Guardian.RulesTestHelper` | `Guardian.Test.Rules` |
| `Guardian.WorkBounds` | `Guardian.Test.WorkBounds` |
| `Guardian.AggregationTestHelper` | `Guardian.Test.Aggregation` |
| `Guardian.QueryApiKeys` | `Guardian.Test.QueryApiKeys` |

`Guardian.TestHelpers` is split by concern:

1. `Guardian.Test.Query`: `resolve_sql/1`, `run_sql/1`, `with_time_limit/2`.
2. `Guardian.Test.Polling`: `eventually/1,2` (`eventually_after_gc/1` was removed by
   [vm-wide-leak-tests](vm-wide-leak-tests.md)).
3. `Guardian.Test.Processes`: queued-call waits and stack-based process discovery, on
   this node or peers (the waits for worker cleanup were removed by
   vm-wide-leak-tests).
4. `Guardian.Test.Segments`: loaded-segment selection, nested-row appends, flat row
   reads (Storage tests only), segment file fixtures and one-call append fault
   injection.

The existing function bodies, timeouts, failure messages and cleanup ordering are
preserved. Cross-concern polling calls name `Guardian.Test.Polling` explicitly.
Tests import only the concerns they use; aliases must not shadow production
modules with the same last name. `Guardian.Test.EnvTest` follows its subject to
`test/guardian/test/env_test.exs` without changing its tests.

Specialized fixtures, fake servers, protocol clients, counter probes/backends,
`Guardian.Query.EvaluationTestCase` and the test-only query function keep their
established homes. Renaming them would add churn outside this shared-helper task.
The only production `.ex` edit updates a helper name in a comment in counter
Context; executable production code is unchanged.

Later, [test support consolidation](test-support-consolidation.md) moved the
counter probes and backend, the fake S3 server, the JSON and MCP clients, the
DistributedStream peer stages and the engine test key under `Guardian.Test.*`.

## Concurrency

Application settings, counter budgets, query-key policy, query time limits and
connected peers require serial tests. Rules' `with_rules/1`, `restart_server/2`
and `publish_module/2` use shared Rules state and also require serial tests.
`compile_module/2` is async-safe when each test uses a distinct probe module.
Pure aggregate arguments and caller reduction measurement are async-safe when
the workload is. Query and process helpers require the caller to isolate the
workload and observed state. Segment helpers require isolated files, tables and
segments; manipulating shared Storage processes requires serial tests.
All existing test async flags are preserved.

## Validation

The plan passed independent Claude and Codex review after clarifying the
source-scan path update, production comment, alias collisions and GC caveat.
After normalizing helper namespaces, imports and the moved source-scan path, an
AST comparison verified all 226 `.exs` files under `test/` (224 test files plus
the bootstrap and a fixture) preserve their test declarations,
async flags and assertions. It also verified all moved and split helper function
bodies are unchanged apart from helper references.

The focused environment, source-style, Rules compiler/counter plan/runtime,
cluster GROUP BY, segment-reader, golden segment-file, mmap and auth route run
passed with warnings as errors: 104 tests, no failures. Independent Claude and
Codex code reviews approved the change, each with five concern helpers. Review
tidy-ups added the missed historical path note, clarified the verification file
count and recorded the namespace convention in CONTRIBUTING.md.

The full pre-commit passed: formatting, test compilation with warnings as errors,
and 1320 tests with no failures (3 excluded). The suite count is unchanged; no
test cases were added or removed.

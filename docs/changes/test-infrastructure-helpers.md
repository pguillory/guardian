# Shared test environment and query peer helpers

Status: implemented and validated.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Query behavior, partition concurrency and counter budgets
are unchanged.

## Problem

Some tests still copied application environment save/restore code or used the
Rules helper's generic environment wrapper. Rules server restart cleanup deleted
the store and extra settings rather than restoring their previous values.

Four query cluster test modules repeated single-peer lifecycle setup. GROUP BY's
routing tests also copied its concurrency setting, so a future executor change
could silently stop exercising merges on both nodes.

## Change

1. Call `Guardian.TestEnv.put/1,2` directly for scoped settings in Rules, query
   result and heap limits (also on a peer), regex memory, persisted-segment
   retirement, discovery and auth tests.
   Remove `RulesTestHelper.put_env/2`.
2. Rules server cleanup stops the test server, restores its previous store and
   settings through TestEnv, then restores whether the previous server was running.
   Consecutive failed starts restore their invalid snapshots without trying to
   restart them; the outer callback restores the original running server. Nested
   restarts and failed starts retain their cleanup ordering and return values.
3. `Guardian.TestCluster.single_peer/0` shares setup and teardown for metadata,
   query failures, GROUP BY and query logging tests. Module-scoped peers remain
   module-scoped; tests that stop a peer still get a fresh peer per test. Cleanup
   registration covers data roots and distribution before startup, and the peer
   controller after `start_peer/1` returns; it does not change that function's
   startup-failure behavior.
4. `await_query_node/1` waits for Storage readiness and the real GROUP BY partition
   lookup. It is a startup barrier, not a guarantee about later lookups. Metadata's
   intentionally booting and failing nodes retain their direct readiness assertions.
5. `Guardian.Query.Executor.group_by_partitions/0` is the shared source for the
   executor, routing tests and readiness helper. Tests still require both nodes'
   partitions and choose groups owned by each node, with all result assertions kept.

## Validation

The Rules server regression checks restoration from real exit callbacks, including
nested restarts, an absent setting and rules reloaded from the original store.
The consecutive-failed-start test also verifies the original store, retry setting
and running server after exit cleanup. The focused Rules server, publisher,
cluster and counter reload run passed (46 tests, no failures).

Independent Claude and Codex plan and code reviews approved the change. The full
pre-commit checks passed: formatting, test compilation with warnings as errors,
and 1310 tests with no failures (3 excluded).

# test-heap-limit: one low query heap limit for the whole test run

## Problem

Tests that needed the query heap limit lower (or back at 256 MiB) changed the
`:query_max_heap_mb` application env at runtime, so `heap_limit_test` and
`regex_memory_test` couldn't run async, and `rules/runner_test` set it per test. Every
other test ran at production's 256 MiB, so nothing noticed a query that grew far past
what it needed.

## Change

1. `config/config.exs` sets `query_max_heap_mb: 16` for the test environment, once.
   It applies to everything that shares the limit: query processes, pipeline
   workers, the large-value `replace` helper and rule workers. Production is
   unchanged: the fixed 256 MiB default, not an operator setting.
2. No test changes it. A heap-limit test runs something that exceeds 16 MiB.
   `heap_limit_test` and `regex_memory_test` are async. The peer test (a remote worker
   follows its own node's limit) moved to `heap_limit_cluster_test`, synchronous
   because it starts a peer; the peer loads no Mix config, so it is at 256 MiB.
3. `Guardian.Test.DistributedStreamStages.grow_heap/1` builds about 40 MB plus its
   stack (1,000,000 tuples), over the test limit and well under production's.
4. Gone: the tests that read the 256 MiB default by deleting the env at runtime, the
   "under the limit it finishes" halves that raised the limit, and the 32 MiB variants
   of the regex tests. `replace_test`'s cap test removes the cap-sized run of `b`
   with 1,024 matches (`b{64}`) instead of 65,537 one-byte ones, which the 16 MiB
   helper can't hold.
5. Coverage lost: the peer test now checks one direction only (low here, the
   peer's own 256 MiB there); it would still pass if remote workers had no limit.
   The other direction needed a test to change the peer's limit.

Why 16 MiB: Preston asked for the lowest value normal tests pass under, guessed at 1
to 10 MB. Calibration: at 2 MiB the suite had 7 failures in 1,179. The floor for
ordinary tests is a pipeline worker on a full mutable segment (16,384 rows), which
needs 12 to 14 MiB. The temporaries tests (GROUP BY/HAVING reassembly during ingest)
and `pipeline_failures_test`'s "counts during ingest" failed at 12 MiB now and then,
and passed at 14. The replace cap test needed 24 MiB until it was rewritten. 16 is one
step over 14, as headroom: the limit is checked at garbage collection, so usage
depends on load. If one of those tests fails with the heap message under load, that is
the margin running out, not a bug.

After this change nothing asserts production's 256 MiB default; it is a constant in
`Guardian.Query.Limits.max_heap_mb/0`.

## Product spec impact

None. Production behavior is unchanged.

## Validation

The default suite passes at 16 MiB; see the commit for the run. `heap_limit_test`
covers a worker, the initial worker and a query over the limit, and
`heap_limit_cluster_test` covers a peer at its own limit.

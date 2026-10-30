# vm-wide-leak-tests: watch leaks through system_stats, not VM-wide test counts

## Problem

Several tests counted resources across the whole VM to catch leaks: live file
mappings and open descriptors (mmap), live native columns, unowned Segment processes
after query temporaries, and processes still running query or pipeline code after a
query or pipeline ended. Anything else in the VM moves those numbers, so the tests
needed slack, waits and a serial run, and they guarded no specific operation's
promise better than a direct check would.

## Behavior after the change

1. Tests don't count resources across the VM (CONTRIBUTING, "Testing philosophy").
   Where an operation promises cleanup, the test checks it on the specific resource:
   the pipeline worker a test holds is awaited with a monitor until it stops.
2. Removed: the descriptor, mapping and live-column counts (`mmap_test`,
   `column_release_test`); the unowned-Segment scan (`temporaries_test`); the
   "no query or pipeline process left" waits in `pipeline_failures_test`,
   `segment_reader_contract_test`, `heap_limit_test`,
   `distributed_stream/failures_test`, the `:cluster` `query_failures_test` and
   `client_peer_test`. A test left checking nothing went with them ("killing the caller
   mid-query stops every query process", whose promise is covered by MCP cancellation
   and by the pipeline consumer-kill test). The helpers `await_no_processes_running/2`
   and `eventually_after_gc/1` are gone.
3. `mmap_test`, `temporaries_test`, `distributed_stream/failures_test` and the moved
   column-survival test run async.
4. `system_stats` gains `open_fd_count`, `mmap_count`, `native_column_count` and
   `rss_bytes` (null off Linux). Each is cheap per sample and never raises: the two
   native counts are atomic reads, and an operating-system value that cannot be read
   is null.

## Product spec impact

`docs/product/spec.md` section 8, `system_stats`: the four new columns, the null
rule, and reading `rss_bytes` as a trend.

## Deploy notes

The new columns appear in `system_stats` rows written after the deploy; earlier rows
read them as null. No migration.

## Validation

The affected test files pass, the `:cluster` ones with `--include cluster`, and the
full default suite passes. `system_stats_test` checks that the new columns are
integers where their source exists and null where it does not.

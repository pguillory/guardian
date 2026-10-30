# Test helper follow-ups

Status: implemented.

Product spec impact: none. Test code and test support only; no `lib/` change.

## Problem

1. Counter tests of results paired larger event budgets with the default batch, whose
   250 ms allowance still capped every call, so a loaded host could fail them (the
   flake `ClientTest` had). `relaxed_options/0` looked like a bigger budget but was
   capped the same way.
2. Polling loops, unique table names and peer setup and cleanup were copied across test
   modules.
3. A garbled comment and one wall-clock lower bound in a lock test.

## Change

1. `Guardian.Test.Counters.Budget.healthy/2` returns event options and a batch with a
   matching allowance (`:scaled` or `:relaxed`); it replaces `relaxed_options/0`,
   `scaled_options/0` and `scaled_batch/1`. Result tests in `counter_rules_test` and
   `client_peer_test` use it or `batch/1`; allowance tests keep production's 250 ms
   batch.
2. `Guardian.Test.Polling` gains `value/3` and `assert_eventually/3` and an interval;
   the local retry helpers are gone. `Guardian.Test.Tables.unique_table/1` replaces
   the copies, and `Guardian.Test.Cluster.bare_peer/1` the peer and distribution
   cleanup blocks. CONTRIBUTING points at them.
3. The store test comment is fixed and the lock test's `remaining_ms > 100_000` bound
   is dropped.

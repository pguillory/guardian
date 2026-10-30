# Test isolation

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Test code and CONTRIBUTING.md only; no production module changes,
and no tenants are added.

## Problem

1. Test isolation had no written pattern, so tests deleted tables before and after
   themselves even though each run starts with a fresh data directory.
2. Thirty test modules were `async: false` without saying why, and some of them
   only used unique tables and private processes.

## Changes

1. CONTRIBUTING.md gains a "Test isolation" section: tests assume every table starts
   empty, each test uses its own table and can run concurrently, and the system's own
   isolation replaces mocks and explicit cleanup. Things that don't need to interfere
   shouldn't; this is about robustness and scale, not multi-tenancy.
2. Redundant per-test table deletes are dropped (EngineTest, StorageTest, QueryTest).
   The two StorageTest cases that fill several segments still delete their tables.
3. These modules are now async: `Guardian.EngineTest`, `Guardian.StorageTest`,
   `Guardian.FormatterTest`, `Guardian.ObjectStoreTest`, `Guardian.ObjectStore.LockTest`,
   `Guardian.Counters.StoreTest` and the `generate_uuid` function test.
4. Every other module that was `async: false` without a stated reason now has a
   short comment naming what it shares across the VM (S3Test, for one, sets the
   S3 timeouts in the application env). `Guardian.QueryTest` stays serial because one
   test refutes "[error]" in captured log output, which sees every process, and
   `Guardian.Counters.BudgetTest` because it depends on 50 ms wall-clock windows. The
   `now` function test also stays serial: it can fail when the clock's second ticks
   mid-test, which load makes likelier (a flake that predates this change).
   Tables that tests reuse across repeated passes get per-invocation names, apart from
   the fixed tables in QueryTest's other tests, which already failed on a repeated pass.

The counter budget tests that relax node-wide budgets are unchanged.

## Validation

The affected files ran under several seeds, and the full suite passes. Runtime of
`mix test --slowest-modules` before and after is in the builder's report.

# Remove the dead column get_value API

Status: implemented and validated.

## Problem

`Guardian.Storage.Column.NIF` declared a `get_value/2` stub, but `nif_funcs[]` in
`src/column.c` had no `get_value` entry: its C implementation had been commented out
since the initial commit (and no longer compiled as written). `load_nif/2` therefore
never replaced the stub, so `Column.get_value/2` always exited `:nif_not_loaded`, and
`Segment.get_value/4` did the same whenever the segment had the column. Nothing in
`lib/` called either; one contract test called `Segment.get_value/4` on a dead segment,
which returns before reaching the stub. Nothing checked that the stub list and the C
table agree, which is how the mismatch went unnoticed.

## Behavior after the change

1. `Column.get_value/2`, `Segment.get_value/4`, the NIF stub and the commented-out C
   function are gone. Rows are still read with `Segment.get_row` and columns with
   `get_column`.
2. `test/guardian/storage/column/nif_test.exs` parses `nif_funcs[]` from
   `src/column.c` (ignoring comments) and checks that the module's functions, less
   `init/0`, equal its entries by name and arity, so a stub without a C entry fails
   the suite. A C entry without a stub already failed it, because the module's
   `@on_load` requires `load_nif/2` to succeed.

## Product spec impact

None. No product interface used these functions, and the column operation never
worked.

## Validation

The parity test passes, and fails with `get_value: 2` restored to the stub list.
The segment reader contract test and the column tests pass, as does the full suite.

# Reject nil counter machine operations

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`; no production callback returns a nil next operation.

## Problem

`Guardian.Counters.Machine.done?/1` uses `op == nil` to recognize a finished
machine. A callback returning `{:next, nil, state}` therefore silently appeared
finished, without producing a result.

## Change

Reserve nil operations for completed machines. `Machine.new/3` requires a non-nil
initial operation, and `Machine.advance/2` raises a fixed `ArgumentError` for
`{:next, nil, state}`, outside the callback-invocation catch. Other malformed
callback returns already raise from transition handling; exceptions during the
callback itself still finish only that machine with `{:error, :invalid_state}`.

A malformed transition is a programming error. It escapes `run_state_machines`,
and `Execution.run_counters/4` catches the failed round and reports failure for
all statements that dispatched machines in that call. Rules fails those statements
open. This deliberately keeps invalid callback returns loud rather than silently
finishing one machine. Existing key machines and their results are unchanged.

## Validation

Machine regression tests cover nil constructor rejection and the nil-next
callback error, alongside valid next/done transitions and callback exceptions.
Related Execution tests cover round failure handling and valid machine execution.

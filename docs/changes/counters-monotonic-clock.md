# Shared counter clock

## Problem

Counters Context, Budget and Transport share one coordinate: the event deadline and
operation timeout, Budget's reservations, settlement timestamps and cooldowns, and
Transport's dispatch deadline (`started + reserved`) are all this node's monotonic
microseconds. Each module read `System.monotonic_time(:microsecond)` itself and
converted milliseconds inline (`* 1_000`, `div(..., 1_000)`, `Integer.floor_div/2` for
Store's millisecond deadline), so nothing named the coupling and a unit change in one
module would silently break the others.

## Behavior after the change

`Guardian.Counters.Clock` owns the coordinate: `now/0`, `from_ms/1`, `deadline/1`,
`remaining_ms/1` (truncated, never negative) and `to_store_ms/1` (floored, comparable
with Store's `System.monotonic_time(:millisecond)`). Context, Budget and Transport use
it instead of their own clock reads and conversions, and Budget names its remaining
microsecond literals (`@batch_allowance_us`, `@suspect_timeout_us`). Clock source,
rounding and values are unchanged; the event deadline is still captured before the
membership snapshot, and Context's `event_ms`/`operation_ms` test seam is untouched.
The remote endpoint still receives a millisecond duration, so nothing changes on the
wire. Mutation TTLs keep using the Rules arrival millisecond coordinate, a separate
contract, and Store keeps its own injectable millisecond clock.

## Product spec impact

None in `docs/product/overview.md` or `docs/product/spec.md`. Security architecture:
none.

## Validation

Independent Claude and Codex plan reviews approved. Focused unit tests cover Clock's
conversions, including floor rounding of negative instants, with bounds bracketed by
clock reads so host load cannot fail them; the existing Context, Budget and Client
tests cover the call sites.
Independent Claude and Codex code reviews approved. The full suite passed 1273 of
1274 tests; the one failure was the load-sensitive limited-reservation timing case in
`client_test.exs` ("owner pipelines run concurrently...", which sleeps 15 ms inside
the production 50 ms operation budget), unrelated to this change, and it passed three
of three isolated reruns. Its stabilization is tracked separately.

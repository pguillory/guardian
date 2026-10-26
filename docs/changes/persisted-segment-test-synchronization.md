# Persisted-segment test synchronization

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Production behavior, storage format and architecture are
unchanged.

## Problem and change

The persistence-failure test created a segment in a spawned process, then waited
only 1,000 ms for the creator to send its PID. A healthy creator delayed by the
scheduler could miss this deadline before the persistence behavior was exercised.
This explicit deadline was shorter than the suite's 5,000 ms receive default.
Scheduler contention is a plausible explanation for the reported loaded-run
failure; the original run did not capture scheduling evidence to establish it.

The fixture now returns the segment through `Task.async` and
`Task.await(:infinity)`. Completion is the synchronization event, and a creator
failure propagates to the test immediately. ExUnit's overall test timeout still
bounds a hung fixture. The creator returns normally, preserving the existing
lifetime: the segment can outlive both its creator and the test while a storage
manager holds it.

The existing persistence-failure assertions remain, and an explicit row read
checks that the retained segment still serves its event. The test still verifies
that the persister survives, logs the write failure once, retains the failed
segment, and persists another segment successfully. No production change is
needed for the demonstrated fixture timeout.

## Validation

An external test wrapper compiled the real test after injecting a 1,200 ms delay
immediately before the creator started its segment. Before the fix, this failed
with `Assertion failed, no matching message after 1000ms` in `unlinked_segment/1`.
After the fix, the same delayed test passed, including both fixture creations,
in about 2.4 seconds. This demonstrates sensitivity to a delayed healthy creator
and the repair's tolerance of that delay, without recreating the original host
load or changing production code.

The injected-delay runs (before and after the fix) and the ordinary focused test
used seed 196276 on Elixir 1.19.3 / OTP 28.5.0.8. Each fixed run passed one test
with no failures.
The normal full pre-commit is the final gate at commit.

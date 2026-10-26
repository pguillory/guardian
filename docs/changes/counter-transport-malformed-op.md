# Refuse malformed anchored counter expiries

Status: implemented.

Product spec impact: none. No statements change in overview.md or spec.md.
Valid TRACK/LOOKUP results, fail-open defaults, deadlines and budgets are unchanged.

## Reachability and failure

`Guardian.Counters.Client.batch/2` delegates directly to Transport. Transport's
routing accepted native increment and CAS operations that had a valid routing key
but a malformed `{:expires, expiry}`. Dispatch reserved allowance before subtracting
the local monotonic clock from that expiry. A nonnumeric expiry raised an
`ArithmeticError`, aborting the batch and retaining the reservation. Rules catches
a counter-batch failure and supplies defaults for the affected statements.
A float did not raise: depending on its value it was reported as expired or sent
to Store, which refused the resulting float TTL.

This path is reachable through the internal Client API, including a trusted peer
calling that API over Erlang distribution. It is not an HTTP/MCP input surface.
Normal rules compute integer expiries from private arrival coordinates and
validated integer windows; row values cannot replace those coordinates. The
dedicated `Transport.remote_operation/3` endpoint bypasses anchored translation
and passes duration-based operations to Store, which already refuses anchored
expiry terms as invalid TTLs. This is internal API validation within the existing
fully trusted distribution boundary, not a new authorization boundary.

## Change

Transport checks anchored increment and CAS expiries are integers before owner
grouping, cooldown admission or budget reservation. A malformed expiry returns
that operation's fixed `{:error, :invalid_request}` without aborting healthy
siblings, writing a value, consuming allowance or changing cooldowns. Store
retains validation of other operands; no broad rescue hides programming errors.

All integer monotonic coordinates remain valid inputs, including negative ones.
An elapsed expiry still returns `{:error, :expired}`. Remaining TTL translation
stays at actual dispatch so queued owners and CAS retries cannot extend a bucket's
lifetime. The owner still receives durations, never another node's clock value.

## Regression coverage

Client tests cover nonnumeric and float expiries for both increment and CAS,
refusal with exhausted allowance or active cooldown, healthy siblings in the same
owner pipeline, successful integer-anchored writes and elapsed integer expiries.
They also check stored values, full healthy refunds and unchanged cooldown state.
The new malformed-request regression failed against the unchanged transport with
`ArithmeticError` on a nil expiry. After the fix, the focused counter tests plus
rule counter-runtime and counter-ingest tests passed: 119 tests, zero failures,
with warnings-as-errors enabled.
No deployment or production-data verification is part of this change.

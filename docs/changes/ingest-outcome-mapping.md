# ingest-outcome-mapping: idempotency outcomes, shared test client, delegate removal

Status: implemented and validated.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. HTTP statuses, JSON bodies, MCP tool results, conflict
messages and idempotency semantics are unchanged.

## Idempotency outcomes

`Guardian.Web.IngestIdempotency.run/5` built the HTTP receipt (`status: 200,
duplicate: true`), the 409 status and the conflict messages, and counted failed
events by reading the HTTP result shape. It now returns plain outcomes:
`{:ran, value}` (this call ran ingestion, claimed or unprotected), `{:duplicate,
failed_events}` or `{:conflict, :changed | :pending | :uncertain}`. Its `ingest`
function returns `{value, failed_events}`; the value is opaque to the coordinator.
`Guardian.Web.Ingest` builds the result, counts failures, and maps outcomes to the
receipt body and the three 409 messages, which the HTTP and MCP layers already
render. Claiming, uncertainty on a caught failure, exact-pid cancellation,
retention and fail-open behavior are unchanged.

Coordinator tests assert the plain outcomes with opaque values and explicit failed
counts, including on the fail-open path. HTTP retry tests pin the full 409 bodies
for all three conflict reasons; mixed-batch receipt counts remain covered at the
HTTP and MCP levels.

## Shared JSON query test client

`QueryLogTest` and `QueryParseErrorsTest` each defined the same JSON `/query`
request wrapper. It is now `Guardian.JsonApiTestClient.query/2` in `libtest/`.

## Failure-classification delegates

The `failure-diagnostics` change left `Guardian.Engine.failure_kind/3`,
`Guardian.Storage.exit_kind/1` and `Guardian.Storage.Segment.exit_kind/1` as
delegates to the leaf `Guardian.Failure`. They are removed; Storage's segment
managers, `Segment`, `Query.Evaluation` and `Query.Failure` call
`Guardian.Failure.exit_kind/1` directly. Labels are identical (same function);
`test/guardian/failure_test.exs` now also pins the cases the removed delegate
assertions covered, including a crash whose stack frame carries arguments. The
coordinator's internal conflict reply is renamed `:changed` to match its outcome.

## Validation

Independent Claude and Codex plan and code reviews approved the change; their
non-blocking findings were applied (the ingest result is matched inside the
coordinator's catch, the internal conflict reply is renamed, a stack-carrying crash
case was added). Focused tests for the touched areas passed, and the sole full
pre-commit passed formatting, warnings-as-errors compilation and 1,245 tests with
zero failures (3 excluded).

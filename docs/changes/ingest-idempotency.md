# Ingest idempotency keys

Status: complete.

## Problem and product impact

A producer may resend a batch after losing its response. Without an idempotency
key, Guardian stores the batch again, and ingest rules run again.

Product spec impact: update sections 4.1 and 4.2 for the optional HTTP/MCP argument
and receipt response, and section 5's duplicate behavior. The overview's writing
description gains the receipt exception. No event format changes.

## Design

The completed public contract lives in [spec section 5, item 9](../product/spec.md#5-ingestion):
key scope and request matching, receipt/conflict behavior, retention, capacity and
best-effort limits. [The API reference](../reference/api.md#retrying-a-batch) keeps
the request/receipt examples and retry guidance. The coordinator mechanism is in
the [ingest architecture](../architecture/system.md#3-ingest-path), and its mandatory
lifecycle and privacy rules are in [Web instructions](../../lib/guardian/web/CLAUDE.md).

The design chose compact receipts instead of caching whole replies to bound memory
without retaining event payloads. Remembering mixed and failed batches prevents a
lost response from replaying successful or uncertain writes. Unknown-outcome
tombstones preserve that distinction when processing aborts. Explicit failure
handling supplements monitoring because HTTP/MCP callers can survive a failed call.

Node-local, ephemeral metadata keeps retry protection independent of peer health
and durable storage. Failing open preserves ingestion availability when protection
is unavailable. Cluster owner routing remains separate follow-up work.

## Validation

Targeted HTTP/MCP/idempotency tests passed (65 tests, zero failures), covering
coordinator concurrency, expiry, capacity, failure and lifecycle behavior, plus
HTTP/MCP integration and storage counts. Formatting and warnings-as-errors
compilation passed. Full suite passed (1,009 tests, zero failures, three large
tests excluded). Independent reviews found stale statements denying all duplicate
suppression, which are now corrected, and small documentation/status-format nits,
also corrected. Added a regression proving retained key strings do not pin a large
request binary, plus checks for changed in-flight payloads, monitor cleanup and
large-object deterministic encoding. Post-review targeted tests passed (42 tests,
zero failures). The pre-commit hook repeats formatting, compilation and the full
suite at commit time.

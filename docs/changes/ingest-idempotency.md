# Ingest idempotency keys

Status: complete.

## Problem and product impact

A producer may resend a batch after losing its response. Without an idempotency
key, Guardian stores the batch again, and ingest rules run again.

Product spec impact: update sections 4.1 and 4.2 for the optional HTTP/MCP argument
and receipt response, and section 5's duplicate behavior. The overview's writing
description gains the receipt exception. No event format changes.

## Design

`idempotency_key` is an optional JSON body or MCP tool argument, null or a UTF-8
string of 1–128 bytes. Its scope is one table on one node. A SHA-256 digest of
deterministically encoded events and return_keys detects changed requests. Omitted
and null return_keys are equivalent; number types and list order must match.

The first request returns the existing ordered per-event results. For ten seconds
after processing completes, a matching retry receives
`{"status":200,"duplicate":true,"failed_events":0}` without running rules or
writing again. The receipt has no results array. Mixed and all-failed batches also
get receipts, with their failed-event count, so retries cannot repeat successful
or uncertain writes. Retry only the failed subset under a new key, respecting
uncertain storage outcomes.

Changed requests and in-flight duplicates get HTTP 409 or MCP tool errors. On an
unexpected failure, keep an uncertain tombstone for ten seconds and report that
events may have been stored. In-flight claims do not expire while the caller is
alive; process monitoring backs up an explicit catch/reraise transition to uncertain.
MCP's existing shared-server serialization remains: a tool call may queue or time
out before it reaches this check. Retry promptly after pending conflicts.

A supervised coordinator before Web keeps at most 10,000 entries across tables:
bounded copies of table/key strings, digest, tokens, monitors, expiry and a failure
count, never event payloads or replies. A completion expiry queue supports expiry
and oldest-completed eviction. Entries expire on access and in a periodic sweep.
At capacity evict completed entries first, including uncertain tombstones; never
evict pending entries. If all entries are pending, or the coordinator is unavailable
or slow, ingest normally without protection and log a fixed info message. No valid
ingest is refused because deduplication is unavailable. Calls have a short timeout;
cancel timed-out claims by token on the exact coordinator process, so a late claim
cannot strand a slot owned by a long-lived caller. Completion failures never hide
the original response.

This is best-effort protection: expiry, eviction, fail-open operation, a coordinator
restart, or a retry reaching another node can allow duplicates. There is no
replication or exactly-once guarantee. Cluster owner routing is follow-up work.

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

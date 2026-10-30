# Test rules

Status: in progress.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Tests, CONTRIBUTING.md and TODO.md only; no `lib/` changes.

## Problem

A passing `mix test` printed hundreds of lines and took about three minutes, much of
it waiting out real timeouts and restart spacing, and some tests were flaky under
load. Many tests checked how Guardian copes with its own parts failing rather than
what it does when they work.

## Rules

CONTRIBUTING.md's "What tests cover" section: test success cases, don't test
timeouts, no sleeps, and don't kill part of the supervisor tree. Existing tests are
brought in line a category at a time.

## Changes

1. Supervisor-tree kills, Storage: SegmentOwnerExitsTest loses its segment-death,
   manager-exit and racing-deletion tests (15 of 20), MutableSegmentsTest its
   killed-segment test, and UnreadableSegmentsTest its startup test, which restarted
   LoadedSegments (the rescan test covers the same loading code). Tests that inject
   other failures (dead PIDs, suspended processes, timeouts) stay until their own
   category is decided. The deleted manager-exit tests had surfaced the FullSegments
   crash cascade, now an open TODO item (full-segments-crash-cascade).

Coverage given up: the manager-exit tests were the only behavioral check that a
graceful MutableSegments or PersistedSegments stop persists writable segments and the
rows reload, and the only test of dropping a mutable segment that died.

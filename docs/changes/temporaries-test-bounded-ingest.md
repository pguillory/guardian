# Temporaries test: bounded ingest

Status: implemented.

Product spec impact: none. No statements change in `docs/product/overview.md` or
`docs/product/spec.md`. Production code is unchanged.

## Problem

`Guardian.Query.TemporariesTest`'s "reassembling queries during ingest see consistent
results" failed once in a default `mix test` run on a loaded machine with the query
heap message (the test environment's 16 MiB limit,
`docs/changes/test-heap-limit.md`), then passed on the next runs.

Its writer appended rows until a check had seen 20,000, with nothing tying the
writer's pace to the checks'. A quiet run stops at about 20,000 to 25,000 rows, two
segments, but nothing bounded the count: a check is a whole query pipeline of several
processes and the writer one process appending in a loop, so whatever slows the
checks more than the writer (such as the rest of the suite's queries and segment
reads) lets the writer run ahead. That link is inferred, not observed: the failed
run's row count wasn't recorded, and busy-looping processes added inside the VM
slowed the writer more than the checks. The bound below removes the variable either
way.

The table's size is what matters to the heap. With the same query over a table that
does not change (no ingest at all):

1. 17,000, 20,000 and 22,000 rows (two segments): no worker's heap reached 4 MiB after
   a collection, and the query passed under a 12 MiB limit.
2. 160,000 rows (ten segments): the query was killed under 12 MiB, and under 16 MiB in
   the one run tried. 400,000 and 1,000,000 rows passed under 16 MiB, and with the
   limit at 256 MiB no worker's heap was over about 10 MiB after a collection at any
   size up to 1,000,000 rows.
3. With a writer like the test's let run to 200,000 rows, the query was killed under 16 MiB at
   about 157,000.

So a worker that reads many segments holds several times what it does for one or two,
up to a level that did not grow from 160,000 to 1,000,000 rows, and whether a run
crosses 16 MiB depends on where the collections fall. The limit is checked at
collection time, which is the overshoot `docs/changes/test-heap-limit.md` describes.

## Production

No evidence of a production issue. For this query the worker's heap follows the
table's segments, and over many segments it levelled off near 10 MiB after a
collection, sampled up to 1,000,000 rows, far under production's 256 MiB. These are
samples of post-collection sizes, not a proof of peak heap in general, and as far as
we can tell load only changed how much data the test made (see Problem). Total query
memory is the open `query-memory-bound` item, unchanged here.

## Change

The writer may not get more than 1,000 acknowledged rows ahead of the count the latest
check started from; past that it waits for the next check. Each check starts while
the writer may still append, and the checks are at most 1,000 rows apart, so ingest
crosses the rollover at 16,384 rows between checks. As before, nothing guarantees a
query overlaps a particular append: a fast writer can use its 1,000 rows before a
query takes its snapshot and then wait. The writer stops within 22,000 rows (the last check under 20,000
started at most 1,000 rows before the next, which can let 1,000 more in), two
segments, and the test asserts it. The heap limit is unchanged.

## Validation

The static-table measurements above were taken with a probe outside the tree, using
`erlang:system_monitor/2`'s `large_heap` events and the heap limit set for the probe.
The focused test file passed five repeated runs; the full default suite passed at
commit.

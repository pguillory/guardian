# Schema.add_segment takes the count and schema

Status: done.

## Problem

`Guardian.Storage.Schema.add_segment/2` called back into the segment it was registering
(`Segment.full!` and `Segment.count!`). A segment that died or hung in between crashed
Schema, which restarts all of Storage. It also stood in the way of segments registering
their own schema, planned in the segment lifecycle consolidation: a segment calling
Schema while Schema called the segment would deadlock.

## Behavior

`Schema.add_segment(segment, table, count, schema)` takes everything it records and never
calls a segment. LoadedSegments, which already read the schema, reads the count too and
passes both. A segment that dies before Schema registers it now crashes only
LoadedSegments (docs/architecture/system.md 4.2, limit 2). `Segment.full!/1` had no
other caller and is gone.

## Product spec

None.

## Validation

The storage tests (`mix test test/guardian/storage test/guardian/storage_test.exs`) and
the full pre-commit suite. Testing a segment that dies mid-registration would mean
killing a process, which CONTRIBUTING rules out.

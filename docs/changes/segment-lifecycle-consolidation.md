# Segment lifecycle consolidation

Status: done.

Preston's design. Before it, a segment moved through four managers (MutableSegments,
FullSegments, PersistedSegments, LoadedSegments), and a persisted segment's ID pointed
at two processes for 10 minutes: the in-memory copy and the one loaded from its file.
Register-before-remove handoffs, reading the registries in lifecycle order, matching
late exits by PID, a second Loaded lookup and a read retry all existed because of that.
A segment whose pack raised at shutdown stopped the rest persisting; a FullSegments
crash lost every writable row; deletion racing persistence left files behind; and the
schema missed full and just-written segments.

## Behavior

1. One process per segment, from creation to expiry or deletion, a `:temporary` child
   of the DynamicSupervisor `Guardian.Storage.SegmentSupervisor`. A crashed segment
   stays dead.
2. Two plain registries of the same `{segment_id, pid, table}` tuple, which monitor
   their segments and link none: ReadableSegments (every segment; loads every file at
   startup; expiry and deletion) and MutableSegments (the writable ones; the append loop,
   unchanged; creating and rotating segments). MutableSegments registers a new segment
   in ReadableSegments before itself, so a row never lands in a segment queries can't
   see.
3. A full or aged segment freezes, registers its final count and schema with Schema
   (each column padded to the row count), and is deregistered by MutableSegments and
   told to persist. In one message it packs, writes its file, maps it back, swaps the
   mapped columns in and hibernates (a full garbage collection). There is no task, no
   queue and no 10-minute cache; `:persisted_segment_cache_ms` is gone. A failed write,
   or a file that won't map, crashes the segment. This replaces the old retry from
   memory: a transient full disk now costs each segment that fills meanwhile its rows,
   where it used to cost nothing until memory ran out.
4. Deletion and expiry stop the segment, waiting for it (one busy writing finishes
   first), then delete its file. A missing file is no longer warned about.
5. SegmentSupervisor, ReadableSegments and MutableSegments are a `:one_for_all` group
   inside Storage's `:rest_for_one`, between Schema and SegmentExpiration. Each segment
   traps exits and writes its file in `terminate` when stopped with `:shutdown` and not
   yet persisted. SegmentSupervisor stops its children concurrently, at a normal stop
   and when the group restarts, so a crash of either registry, or of the supervisor
   short of a kill, writes the writable segments before the reload. Not on `:normal`
   (deletion) or a crash (columns may be half-appended).
6. Shutdown: each segment has 90 s, all at once, so Storage stops in about 90 s at worst,
   down from 110 s.
7. ReadableSegments loads into a table under another name and renames it when the load
   is done, so a query during a reload fails instead of answering from part of the
   data.
8. Schema reads list writable segments before Schema, so a freezing segment is counted
   twice for a moment rather than missed. SegmentExpiration skips its tick while
   Storage is not ready, since it outlives a restart of the group.
9. `Guardian.Storage.segment_ids/1` lists newest first. The query error for a segment
   that stops mid-query says "(it was deleted or expired, or its machine's storage
   restarted)" instead of "(... or moved to its file)".

## Product spec

`docs/product/spec.md`: section 7 (a query reading a segment while it is written waits
and gets the same rows; no stored-copy retry); section 9 items 2 (no handoff) and 3 (the
90 s budget, a failed write losing only its own segment, a crash of the processes that
track segments persisting before the reload); section 12 gap 1 (now a write failure
losing the segment's rows), gap 9 (any in-memory segment crash, including filling
while Schema restarts), gap 11 (no 10-minute reprieve) and gap 12 (second sentence
gone).

## Validation

The default suite and `mix test --include cluster --include lifecycle`, with a new
lifecycle test that rows a segment persisted while running come back once after a
restart, and Storage and Segment tests for persisting, the swap, the schema registered
at freezing, writing at a shutdown stop, and deleting a persisted segment's file. By hand
(a throwaway script against a fresh data directory): killing MutableSegments and then
ReadableSegments with rows in memory kept every row through the group restart; killing
SegmentSupervisor itself lost the writable segment's rows, as expected for a kill. With
3,000 files reloading after MutableSegments was killed, every row count asked during the
reload failed (about 160,000 tries) and none returned a partial count.
A rotation on production is checked by hand after deploy.

# Segments load at startup only

Status: done.

Preston's decisions on segment loading: a freshly written file that won't load is not
rescued, the periodic scan goes, and a file that fails to load is logged and skipped at
startup. Guardian puts availability and simplicity ahead of consistency.

## Behavior

1. A file loads right after it's written, not at eviction. PersistedSegments writes the
   file, sends itself a message, and on that message asks LoadedSegments to load it. The
   load can't run inside the persist pass, because `terminate` runs that pass too, and a
   dead LoadedSegments would then abort shutdown persistence. A load message left in the
   mailbox when PersistedSegments crashes is lost, and so is the load of any file
   `terminate` writes on that crash. Those files wait for the next restart. At eviction PersistedSegments only retires the in-memory copy.

   The scan used to do this within a minute. Waiting for eviction instead would have
   hidden new tables and columns from schema reads for 10 minutes, and left the file
   behind when a cached segment was deleted.
2. No rescue. If the file won't load, LoadedSegments logs its one error line and the
   file stays on disk. The in-memory copy serves until eviction, then those rows are
   gone from queries. There's no rewrite from memory, no retry, and no separate check
   after writing: loading the file to serve it is the only check.

   This is deliberately not a manager crash. A crash of PersistedSegments restarts
   MutableSegments and SegmentExpiration too (`:rest_for_one`) for no benefit.
3. Files load at startup and right after they're written, and nowhere else. The 60-second
   scan and `LoadedSegments.rescan/0` go. Consequences:
   - A loaded segment that crashes comes back at the next restart. Its rows are silently
     missing from queries until then. Accepted.
   - A cached segment that crashes normally loses nothing, since its file is already
     loaded. If it crashes in the instant before the load message runs, its file waits
     for the next restart: the EXIT handler doesn't load anything.
   - Restoring or removing a file on the volume takes effect at the next restart. A
     loaded segment whose file is removed by hand keeps serving until then, past
     retention if need be, since expiry no longer sees it.
   - A file left by deletion racing persistence comes back at the next restart rather
     than the next scan.
4. The skipped-file map and its fingerprints go. Only expiry needed them, and it no
   longer does: `SegmentExpiration` lists the segment directory instead of asking the
   registries, so unreadable files, and the files of crashed segments, expire on the
   same 15-day schedule as any other.
   - Expiry can't touch a file being written: writes go to a `{final}.{n}.tmp` name,
     which doesn't parse as a segment, and the rename is atomic.
   - Expiry can't touch a file that's still in retention. Past 15 days it unloads a
     served copy as it always did, serialized with loads in LoadedSegments. A cached
     copy of a segment persisted more than 15 days after its creation keeps serving
     from memory until its eviction.
   - `Guardian.Storage.delete_segment/1` and `delete_table/1` don't see a file that isn't
     loaded: they know only what's registered. An operator can remove the file by hand
     or let it expire.
5. A file that fails to load at startup logs its own line and Storage still comes up.
   That's already so; no code changes.
6. The "Storage: loaded N segments (M skipped)" line goes.

## Tests

Tests that loaded files with `rescan/0` use `LoadedSegments.ensure_loaded/2` instead.
Tests of rescans and the skip memory go. One `:lifecycle` test covers a bad file at
startup, with no `capture_log`. A log line on a peer can't be asserted without reaching
in, so the test covers the skipping, not the line. The failed load at eviction has no
test: it would need a file damaged between its write and its load, which can't be done
without reaching inside. Old-file expiry keeps a test, adapted: an old file that was
never loaded is deleted, and a fresh one and an old temp file stay. An agent checks by
hand (insert, stop, start, query), since this touches segment lifetimes. A test covers
a table staying in the schema once its rows are persisted, which is what the load right
after writing is for.

## Product spec impact

Section 9 item 6 (Rescans) is replaced by a restart rule, sections 7 and 10 item 6 get a
qualifier on "never a partial answer", and section 12 gains the rows that go silently
missing from queries: a skipped file's, a crashed loaded segment's until a restart, and
those of a file written but not yet loaded when a storage manager crashes.

Parked: whether segments should load at startup at all.

# Storage Subsystem

Storage is Guardian's custom columnar event store. Operations are scoped by
table and persisted files are named `{table}.{segment_id}.seg`. The parser only accepts
generated segment IDs; any other `.seg` file (such as the older
`{user_id}.{table}.{segment_id}.seg` format) is ignored with one startup warning and
never deleted.

## Public boundary

`Guardian.Storage` is the public API (see its moduledoc); so are the data modules
`Guardian.Storage.Column`, `Guardian.Storage.Column.Metadata`, `Guardian.Storage.Value` and `Guardian.Storage.Flattening`,
which hold no processes. Everything else here is internal and marked
`@moduledoc false`: `Guardian.Storage.Segment`, `MutableSegments`, `ReadableSegments`,
`SegmentExpiration`, `Segment.Registration`, `SegmentFile`, `Guardian.Storage.Schema`,
`BlobStore`, `Mmap`, and the `@doc false` function `Guardian.Storage.get_segment/1`. Code outside
`lib/guardian/storage` names a segment by its ID and reads it with `Guardian.Storage.segment_row_count/1`
or `Guardian.Storage.get_column/2`; it never holds a segment PID or calls an internal module.
There is no xref check: keep to this by convention and in review. Tests under
`test/guardian/storage` may use the internals. Other tests and the shared helpers in `libtest`
may use them only to set up a segment's state or inject faults into its process
(suspending, killing, or swapping a segment).
The exceptions:

- `Guardian.Test.Segments.segment_row/2` reads a flat row, for the tests under
  `test/guardian/storage` only.
- `test/guardian/query/segment_reader_contract_test.exs` tests that a segment gone
  before its columns are read fails the query, naming it. Slow and vanishing segments
  mid-query are checked by hand (`docs/changes/async-default-tests.md`).

Query results are still checked through queries.

## Segment lifecycle

A segment is one process for its whole life, under the DynamicSupervisor
`Guardian.Storage.SegmentSupervisor` as a `:temporary` child: a crashed segment stays
dead, and the supervisor and its crash report log it.

1. MutableSegments starts it under SegmentSupervisor with its ID and table, registers it
   in ReadableSegments, then in its own table. Readable first: an appender can use the
   segment as soon as it is in MutableSegments, and its rows must be readable once the
   append returns.
2. Appends go to it while it is in MutableSegments.
3. When it is full or reaches its maximum age it freezes: it stops accepting rows and
   registers its final count and schema (each column padded to the row count, as the
   file will hold it) with Guardian.Storage.Schema, once. MutableSegments then
   deregisters it and casts `Segment.persist/1`.
4. Persisting runs inside the segment, in one message: pack every column, write the file
   (temp, fsync, rename), map it back, swap the mapped columns into its state, and
   hibernate, which is a full garbage collection that releases the native and packed
   columns. Reads and appends queued behind it wait. A failed write, or a file that
   won't map, fails a match and crashes the segment. There is no task, no queue of full
   segments and no cached copy.
5. It stays in ReadableSegments, served from the mapping, until expiry or deletion.

ReadableSegments and MutableSegments are plain registries of the same
`Segment.Registration` tuple: register, deregister, look up, and monitor. Neither links a
segment or traps exits, and a `:DOWN` removes only the registration holding that PID, so
a late DOWN from a segment already persisting or deleted matches nothing. Only the
owning module touches its ETS table. ReadableSegments loads every file in its `init`
into a table under another name and renames it to its own when every file is in: keep
it that way, so a query during a reload fails rather than answering from part of the
data. It owns expiry and deletion: it deregisters the segment, stops it with
`Segment.retire/1` (`:normal`, waiting until it is gone, so a segment busy writing
finishes first), then deletes the file; a missing file is not logged, since a writable
segment never had one. SegmentExpiration lists the segment directory and calls
`ReadableSegments.delete_file/2`, and skips its tick while Storage is not ready. Code
holding a segment's PID must cope with it stopping at any moment.

SegmentSupervisor, ReadableSegments and MutableSegments are a `:one_for_all` group, in
that order, inside Storage's `:rest_for_one` (Schema first, SegmentExpiration last). Each
segment traps exits, and its `terminate` writes its file if it has rows, is not yet
persisted, and the reason is `:shutdown` or `{:shutdown, _}`: never on `:normal`
(deletion) or a crash (its columns may be half-appended). SegmentSupervisor stops its
children concurrently, each within its 90 s budget, at a normal stop and at a restart of
the group, so a crash of either registry or of the supervisor writes the writable
segments' files before the restart reloads every file. A segment that is persisting
when the stop arrives finishes first, then has nothing to write. The registries do
nothing at shutdown.

A segment file that cannot be loaded (truncated, empty, malformed header) must not
take ReadableSegments down. The segment validates the file in `init` and stops with
`{:shutdown, {:unreadable_segment, kind}}`, which `DynamicSupervisor.start_child/2`
returns without a crash report. ReadableSegments logs the failure without the file's
bytes and remembers nothing: the file stays on disk, the next restart tries it again,
and SegmentExpiration deletes it on the usual schedule. Never log an exception message,
stack trace, or argument list from segment loading: they carry segment data. Native
column asserts on corrupt bytes still abort the VM: packed columns are not yet validated
before the NIF reads them.

Segment readers (`count`, `full`, `keys`, `schema`, `get_column`) are
monitored calls that return `{:error, {:segment_unavailable, reason}}` when the
segment is gone or dies, instead of exiting the caller. Their timeout defaults to
`:infinity` for queries. Storage's own callers use the bang readers (`count!`,
`keys!`, `get_column!`), which wait at most 5 s so a hung segment
can't block them and exit with only the reason's kind.
`Guardian.Storage.schema/1` shares that budget and exit through
`Segment.storage_read_timeout/0` and `Segment.exit_unavailable/1`. Registries never
call a segment, except deletion's stop; MutableSegments casts `persist`. Log an exit reason only through
`Guardian.Failure.exit_kind/1`: a crash reason can carry rows.

`Guardian.Storage.segment_row_count/1` and `Guardian.Storage.get_column/2` resolve the ID
in ReadableSegments on every call and read once: an ID names one process for its whole
life, so there is no retry. A persisted segment's mapped columns are byte for byte the
packed columns it served before, and its count is fixed from freezing, so a query
reading across the swap sees the same rows.

Guardian.Storage.Schema tracks the metadata of frozen segments, which register
themselves when they freeze (loaded segments in `init`), and never calls a segment.
`Guardian.Storage.schema/1` lists the writable segments first, then merges Schema's
metadata with each writable segment's, skipping one that is deleted or stops while it
reads and failing on one that does not answer in 5 s. Because a segment registers with
Schema before it leaves MutableSegments, one changing state during the lookup is counted
twice for a moment rather than missed; `table_names/0` reads in the same order. A
frozen segment's metadata is subtracted when its process stops, so deletion and expiry
must stop the process; a table leaves Schema with its last frozen segment. Schemas are
inferred; there is no metadata DB.

A mutable segment is full when it holds `capacity` rows or when the packed size of its
columns (each padded to the row count) reaches its byte budget (`max_bytes`, 64 MiB).
MutableSegments also configures a one-hour maximum age, starting a segment's timer
at its first successfully stored row. Expiry freezes the segment and persists it as size rollover
does; later writes retry in a new segment. Empty segments have
no timer. Set `:guardian, :mutable_segment_max_age_ms` or the runtime environment
variable `GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS` to a positive millisecond duration.
The age bounds when persisting begins.
Columns have no per-layer size caps. The byte budget is soft: the row that crosses it
is stored, the append replies `{:ok, :full}`, and MutableSegments normally has the
segment persist at once, as it does for the row that reaches `capacity`.
(If that caller dies first, the next append gets `{:error, :full}` and does it.)
A full segment replies `{:error, :full}` and MutableSegments retries the row in a new
segment. A valid value always fits a column. The
budget bounds accumulated data, not memory: mutable columns can hold about twice their
packed size. New columns start empty and
grow with use, so sparse keys stay cheap. Rows are appended atomically: every value is
validated before any column is changed. MutableSegments' monitor unregisters mutable segments
that die, and `Segment.append/2` reports a segment that is gone as `{:error, :dead}` so
the row is retried elsewhere. A segment that crashes while handling a row is not
retried. Below Storage there is one append path, for flat rows that return explicit
refusals: `MutableSegments.append/2` (the retry loop) and `Segment.append/2`. The
wrappers live only in `Guardian.Storage`: `Guardian.Storage.append/2` flattens first,
`Guardian.Storage.append_flattened/2` stores a row that is already flattened (as Engine does
after validating it), and both raise `ArgumentError` on a segment's refusal, which
`Guardian.Storage.append_flattened_result/2` returns as `{:error, :invalid_value}`. Exceptions
and exits still propagate from every path and may occur after a row was stored. Engine
does not catch them: the whole request fails. An unexpected insert failure crashes the
segment, losing the rows it holds in memory, acknowledged ones included (spec section 12).

Native column resources never leave their Segment process (column.c has no locks, and
`append` grows and reallocates its buffers). `get_column` replies with a packed binary: for a
mutable column, a snapshot padded to the row count, built in the segment and cached until
the row count changes. Persisting packs every column inside the segment, reusing cached
snapshots. Costs: an append
waits behind the reader calls queued ahead of it, each one column's pad and pack. The
cache bounds the number of packs, not their time, so a huge column on a slow machine
could still approach `append`'s 5 s call timeout. Under sustained reads, each append
invalidates the cache, so hot-segment ingest slows with read load. An idle mutable
segment keeps one packed copy per key read since its last append.

Stored rows accept scalar/list/map values supported by `Guardian.Storage.Value`, whose rules
come from the column NIF (`Guardian.Storage.Column.valid_value?/1`). `Guardian.Storage.append/2`
flattens nested maps into dot-notation columns (`Segment.append/2` takes flat rows),
and rows stay flat when read: nothing rebuilds nested JSON from them. Column packing
uses the native implementation under `src/column.c`. Persisted segments map their file
with `Guardian.Storage.Mmap` (`src/mmap.c`), which closes the descriptor once the file is mapped
and unmaps it when the last binary referring to it is collected.

`Guardian.Storage.SegmentFile` is the one home of the on-disk format: segment filenames
(`filename/2`, `parse_filename/1`, `unparseable/1`) and the file's contents
(`write/4`, `read/1`). It holds no process logic; Segment calls it to persist and to
load. `test/guardian/storage/segment_file_golden_test.exs` pins the format byte for byte
against `test/fixtures/segment_file.seg`. Do not change the binary format or filename
format as a side effect of unrelated work. Such changes require an explicit migration
plan and dedicated tests, and a new fixture only with that plan.

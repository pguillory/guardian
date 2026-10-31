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
`@moduledoc false`: `Guardian.Storage.Segment`, the four managers, `SegmentExpiration`,
`Segment.Registration`, `SegmentFile`, `Guardian.Storage.Schema`, `BlobStore`, `Mmap`, and the
`@doc false` functions `Guardian.Storage.get_segment/1` and `unloaded_segment_ids/1`. Code outside
`lib/guardian/storage` names a segment by its ID and reads it with `Guardian.Storage.segment_row_count/1`
or `Guardian.Storage.get_column/2`; it never holds a segment PID or calls an internal module.
There is no xref check: keep to this by convention and in review. Tests under
`test/guardian/storage` may use the internals. Other tests and the shared helpers in `libtest`
may use them only to set up a segment's state or inject faults into its process
(suspending, killing, or swapping a segment, or picking which copy a test holds).
The exceptions:

- `Guardian.Test.Segments.segment_row/2` reads a flat row, for the tests under
  `test/guardian/storage` only.
- `test/guardian/query/segment_reader_contract_test.exs` tests that a segment gone
  before its columns are read fails the query, naming it. Slow and vanishing segments
  mid-query are checked by hand (`docs/changes/async-default-tests.md`).

Query results are still checked through queries.

## Segment lifecycle

1. MutableSegments owns writable in-memory segments.
2. FullSegments holds segments awaiting persistence.
3. PersistedSegments packs and writes full segments, retaining a short-lived cache.
4. LoadedSegments memory-maps persisted segments for queries: every file at startup,
   then each file right after it is written. Nothing else loads a file.

Every ownership handoff registers its destination before removing its source.
Segment-ID enumeration reads Mutable, Full, Persisted, then Loaded to preserve
visibility during transfers; overlapping IDs are globally deduplicated. PersistedSegments
loads a file right after writing it, from a message to itself so that `terminate`'s
persist pass never calls LoadedSegments. Eviction then retires the in-memory process
(lookups check Loaded first, so normally no read holds its PID; one that does is
retried once on the loaded copy, below). A file that won't load is not rescued: the
in-memory copy serves until eviction, then its rows are gone. Loading the file is the
only check on it. The cache window is `:guardian, :persisted_segment_cache_ms` (default
10 minutes). A delayed load delays persistence; shutdown retains its existing bounded
budget. Segment lookup retries Loaded after searching the forward lifecycle path
because the first Loaded lookup may precede a handoff.

Each manager owns its segments' exits. All four link their segments and trap exits. An `{:EXIT, pid, reason}`
removes only the registration holding that PID, never one found by ID alone, because a
late EXIT can follow a handoff, a retirement, or a reload of the same ID; one that
matches nothing is ignored. Log an exit reason only through the leaf
`Guardian.Failure.exit_kind/1`, which names its kind: a crash reason can
carry rows. Managers stop a segment only with
`Segment.retire/1` (or `Registration.retire/2`, which also unregisters it), which
returns once the process is gone even if it already died or dies concurrently; a bare
`GenServer.stop/3` crashes the caller then. Deletion and every manager's `terminate/2`
retire what they own (MutableSegments' `terminate` hands
its segments to FullSegments instead).
The registry operations the managers share (listing IDs, looking a segment up,
retiring by ID or all) are plain functions in `Segment.Registration`, which each
manager wraps. Only the owning manager's module touches its ETS table: other modules
call that module's functions (SegmentExpiration lists the segment directory and
calls `LoadedSegments.delete_file/2`). During a handoff both managers link the
segment, destination first. Retirement waits without a timeout, so anything registered
as a segment must answer system messages.

A segment file that cannot be loaded (truncated, empty, malformed header) must not
take LoadedSegments down. `Segment.load/1` starts the segment unlinked and validates
the file in `init`, returning `{:error, {:unreadable_segment, kind}}`; a segment that
loaded links itself to the caller before `init` returns. LoadedSegments logs the
failure without the file's bytes and remembers nothing: the file stays on disk, the
next restart tries it again, and SegmentExpiration deletes it on the usual schedule.
Never log an exception message, stack trace,
or argument list from segment loading: they carry segment data. Native column asserts
on corrupt bytes still abort the VM: packed columns are not yet validated before the
NIF reads them.

Segment readers (`count`, `full`, `keys`, `schema`, `get_column`) are
monitored calls that return `{:error, {:segment_unavailable, reason}}` when the
segment is gone or dies, instead of exiting the caller. Their timeout defaults to
`:infinity` for queries. Storage's own processes use the bang readers (`count!`,
`full!`, `keys!`, `schema!`, `get_column!`), which wait at most 5 s so a hung segment
can't block them and exit with only the reason's kind.
`Guardian.Storage.schema/1` shares that budget and exit through
`Segment.storage_read_timeout/0` and `Segment.exit_unavailable/1`. The writers
(`freeze`, `pack`, `store`, `put_column`, `update_count`) are plain 5 s
`GenServer.call`s that exit on failure; `GenServer.call` drops a reply that arrives
after its timeout. Log the reason only through `Guardian.Failure.exit_kind/1`.

`Guardian.Storage.segment_row_count/1` and `Guardian.Storage.get_column/2` resolve the ID on every call.
If the process they resolved stopped normally (`:normal`, `:shutdown`,
`{:shutdown, _}`) or was already gone (`:noproc`) and the ID now resolves to a
different process, they read once more from that process and return its result,
even a second failure (there is no further retry). A crash, or an ID that resolves
to nothing or to the same process, returns the first error.
This is safe because a segment ID only ever moves to a copy made from the same frozen
process (its file), whose rows start with the same rows, and query reads are cut to
the snapshot's row count (checked by hand since its test went:
`docs/changes/async-default-tests.md`). Keep it that
way: never let an ID resolve to a process holding different rows. A side effect:
`delete_segment` retires the Persisted copy before the Loaded one, so a read on the
Persisted copy during a delete can retry onto the Loaded copy and return its rows
instead of the error; the read finishes before the delete does.

Guardian.Storage.Schema tracks metadata for loaded full segments. `Guardian.Storage.schema/1` combines
that metadata with mutable segments, skipping one that is deleted or stops while it
reads and failing on one that does not answer in 5 s. A loaded segment's metadata is subtracted when
its process stops, so unloading a segment (expiration or deletion) must stop the
process; a table leaves Guardian.Storage.Schema with its last loaded segment. Schemas are
inferred; there is no metadata DB.

A mutable segment is full when it holds `capacity` rows or when the packed size of its
columns (each padded to the row count) reaches its byte budget (`max_bytes`, 64 MiB).
MutableSegments also configures a one-hour maximum age, starting a segment's timer
at its first successfully stored row. Expiry freezes the segment and uses the same
handoff as size rollover; later writes retry in a new segment. Empty segments have
no timer. Set `:guardian, :mutable_segment_max_age_ms` or the runtime environment
variable `GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS` to a positive millisecond duration.
The age bounds when handoff begins, not when a queued write reaches disk.
Columns have no per-layer size caps. The byte budget is soft: the row that crosses it
is stored, the append replies `{:ok, :full}`, and MutableSegments normally hands the
segment off for persistence at once, as it does for the row that reaches `capacity`.
(If that caller dies first, the next append gets `{:error, :full}` and hands it off.)
A full segment replies `{:error, :full}` and MutableSegments retries the row in a new
segment. A valid value always fits a column. The
budget bounds accumulated data, not memory: mutable columns can hold about twice their
packed size. New columns start empty and
grow with use, so sparse keys stay cheap. Rows are appended atomically: every value is
validated before any column is changed. MutableSegments unregisters mutable segments
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
the row count changes. `Segment.pack/1` freezes the segment and packs one column per
call inside it, reusing a cached snapshot. `store`
asks it for the packed columns, and `put_column` accepts only binaries. Costs: an append
waits behind the reader calls queued ahead of it, each one column's pad and pack. The
cache bounds the number of packs, not their time, so a huge column on a slow machine
could still approach `append`'s 5 s call timeout. Under sustained reads, each append
invalidates the cache, so hot-segment ingest slows with read load. An idle mutable
segment keeps one packed copy per key read since its last append.

Stored rows accept scalar/list/map values supported by `Guardian.Storage.Value`, whose rules
come from the column NIF (`Guardian.Storage.Column.valid_value?/1`). `Guardian.Storage.append/2`
flattens nested maps into dot-notation columns (`Segment.append/2` takes flat rows),
and rows stay flat when read: nothing rebuilds nested JSON from them. Column packing
uses the native implementation under `src/column.c`. Loaded segments map their file
with `Guardian.Storage.Mmap` (`src/mmap.c`), which closes the descriptor once the file is mapped
and unmaps it when the last binary referring to it is collected.

`Guardian.Storage.SegmentFile` is the one home of the on-disk format: segment filenames
(`filename/2`, `parse_filename/1`, `unparseable/1`) and the file's contents
(`write/4`, `read/1`). It holds no process logic; Segment calls it to store and to
load. `test/guardian/storage/segment_file_golden_test.exs` pins the format byte for byte
against `test/fixtures/segment_file.seg`. Do not change the binary format or filename
format as a side effect of unrelated work. Such changes require an explicit migration
plan and dedicated tests, and a new fixture only with that plan.

# Flat ingest results

Status: complete.

`send_events` (HTTP and MCP) returns each stored event as the flat row it was stored
as, and `return_keys` reads exact columns. Guardian used to rebuild nested JSON for
the result, with about seventy lines of checks and fallbacks for the shapes that
cannot be rebuilt, and nobody could name a reason for it. `return_keys` is for
reading decisions and computed values, not for echoing a big object back, and a flat
row is exactly what queries see. All rebuilding goes: Engine's reported event,
`Guardian.Storage.Flattening.unflatten_event/1` and its column-to-event helpers, the
column-name decoder, and `Guardian.Storage.Segment.get_row/3`, which only tests
called.

Product spec impact: `docs/product/spec.md` section 3 item 2 (what the ingest key can
read), section 4.1 (`return_keys`), section 5 item 4 (drops and the result), section
6.3 (flattening, and ingest results are flat) and section 12 item 6 (the edge case
that could not be rebuilt). `docs/product/overview.md`: none.

## Behavior

1. A successful result's `event` is the row as stored, after rules: keyed by column
   name, exactly as queries see it. `{"user": {"name": "Bob"}, "tags": ["a"]}` comes
   back as `{"user.name": "Bob", "tags": ["a"]}`; a list of objects is one list per
   key, padded with null for items without it (`users..age: [null, 3]`); keys with a
   dot, a quote or nothing are quoted (`"a.b".c`). The envelope is unchanged.
2. `return_keys` names exact columns. `["user.name"]` reads `user.name`; `["user"]`
   reads only a column named `user`. Missing columns read null, `[]` returns `{}`,
   omitted or null returns the whole row.
3. Dropped values (invalid values and over-long flattened keys, sent or produced by a
   rule) are reported by absence, as before: the column is missing from the whole row
   and reads null through `return_keys`. There is no list of dropped columns or
   reasons: nothing reads drops today, and the flat row already shows exactly what
   was stored. `return_keys: []` reports nothing.
4. Empty objects and empty lists store no column and are absent from the result.
   Before, the original event (with them) came back when nothing was dropped.
5. A sender's nested key under a rule's output name (`decision.x` beside a rule's
   `decision`) no longer blanks the output: both are columns. The spec's warning
   that a caller must not treat a null output as a decision is gone. The warning
   that a skipped `WHERE` keeps a sender-supplied output stays.
6. `Guardian.Engine.ingest_event/2` and `log_event/2` return the stored flat row.

## Design

1. Engine: the validated row (after rules, re-validated) is stored and returned. The
   rules' output row is always validated, even when unchanged, in the same catch that
   reports "internal error before storage; the event was not stored".
2. Flattening keeps `flatten_event/1`, `flatten/1`, `encode_path/1` and `pad/3`.
3. Tests read segment rows through `Guardian.Test.Segments.segment_row/2`, a flat
   reader for Storage tests only (`lib/guardian/storage/AGENTS.md`). The race fixture
   keeps its column readers; its row reader and segment_test's concurrent `get_row`
   test went with `get_row`. `Guardian.Test.EngineKey` became
   `Guardian.Test.RaisingValue`, raising while flattening enumerates it.
4. TODO entries made obsolete: `engine-single-flatten`,
   `fix-unflatten-nil-list-items`, `decode-path-hardening`.

## Upgrade

No data migration. A client that omits `return_keys`, or names a top-level field
holding a nested object, sees flat columns instead. During a rolling deploy, results
differ by node until every node runs the new build. Clients that send
`return_keys: []` see no change.

# Generic folder object store

Status: complete.

`Guardian.Rules.Store.Local`, the rule folder, is a `Guardian.ObjectStore` that knows
rule policy: it lists only `<table>/*.gsql` files and the lock file, and refuses any
other key. That is a generic mechanism (a folder of keyed objects with conditional
writes) carrying a feature's layout, the follow-up named in
`docs/changes/object-store-lock.md` ("Not in this change"). This change replaces it with
a generic `Guardian.ObjectStore.Local` that lists every object in the folder, and
leaves the rule layout to Rules, which already applies it to S3 listings.

## Behavior change: stray and misplaced files in a local rule folder

A local rule folder becomes read exactly like an S3 bucket already is. Today, for a
local folder only:

| File in the rule folder | Today | After |
| --- | --- | --- |
| `x.gsql` (no table folder) | not listed, silently ignored | listed; a validation error ("a rule file must be `<table>/<name>.gsql`") attributed to no table: logged by file and kind at load and reported among a write's remaining errors; no table becomes invalid and writes still succeed |
| `t/sub/a.gsql` (nested too deep) | not listed, silently ignored | listed; the same validation error, attributed to table `t`, so `t` is invalid: published invalid at boot (its API ingests fail), or a running node keeps `t`'s previous good rules and logs the error. Tables tied to `t` by counter LOOKUPs follow the existing rules for an invalid table (invalid at boot; retained or deferred with `t`'s component on reload); unrelated tables run. Writes still succeed (an existing error is not a new one) |
| `t/a.txt`, `README`, `t/sub/notes` (not `.gsql`) | not listed | listed and read (hashed) on every load, reload and 60 s poll, then ignored by Rules. If one cannot be read (permissions), the listing fails: boot refuses to start, a running node keeps its rules and logs the poll failure |
| Dot files and folders (`.DS_Store`, `t/.a.gsql`, `.git/`) | not listed | still not listed |
| A folder named like a rule file (`t/a.gsql/`) | not listed | still not listed (only regular files are objects) |
| `t/a.gsql`, `Bad/a.gsql`, `t/Bad.gsql` | listed (the last two as validation errors) | unchanged |
| A temporary file left by a crashed write (`{name}.{n}.tmp`, `Guardian.AtomicFile`) | not `.gsql`, not listed | not listed (the store skips its own temporary files) |
| A name that is not valid UTF-8 | not listed unless it is `*/*.gsql` | not listed (keys are UTF-8, as on S3) |
| `GUARDIAN_RULES_DIR` set to the data folder, one containing it, or one inside `segments` | starts; lists only `*/*.gsql` | refuses startup: the walk would hash every segment file each poll |

S3 and R2 stores are unchanged: they already list everything under the prefix and
apply these rules. `list_rules` (MCP) still shows only valid rule files.

## Layout

1. `Guardian.ObjectStore.Local` (new, `lib/guardian/object_store/local.ex`), replacing
   `Guardian.Rules.Store.Local`. Same `new/1`, `describe/1`, content-hash ETags,
   store-clock `age_ms` from the file's mtime, conditional puts serialized per folder on
   this node with `:global.trans`, writes through `Guardian.AtomicFile.write/2` (from
   `atomic-write-helper`, which lands first). Differences:
   - `list/1` walks the whole folder: every regular file at any depth, key = its path
     relative to the folder with `/` separators, sorted. Names starting with `.` (files
     or folders) are skipped, as are names that are not valid UTF-8 and
     `Guardian.AtomicFile` temp files (`Guardian.AtomicFile.temp_file?/1`, a name
     ending `.<n>.tmp` with `n` a positive integer, the shape `write/2` creates). A file or folder
     that disappears mid-walk is skipped (`:enoent`); any other error fails the
     listing. Symlinks are followed as today (a symlinked file or folder counts as what
     it points to), now at any depth; they are operator configuration and may lead
     outside the folder. A folder already being walked above itself (a symlink back up
     the tree, by device and inode) is skipped rather than walked again.
   - ETags are hashed while streaming the file, so a large stray file costs a read but
     not its size in memory; the listed size is the bytes hashed.
   - The walk is bounded: config field `max_entries` (default 20,000, the same order
     as S3's 20 pages of 1,000) caps the directory entries visited; past it the listing
     fails with `{:failed, "too many objects"}`, like S3's page cap. It bounds
     traversal work, not each directory's listing.
   - Key safety is generic and replaces the rule-key whitelist as the lexical
     path-traversal guard: a key is a non-empty valid UTF-8 binary of `/`-separated
     segments, each non-empty, not `.` or `..`, not starting with `.`, without a NUL
     byte, and not shaped like a temp file. That excludes absolute paths, `//`, and
     traversal, and makes every accepted key one `list/1` can return. It does not
     contain symlinks inside the folder, which (as today) are trusted operator
     configuration. `get`, `put` and `delete` with another key return
     `{:error, {:failed, "invalid key"}}` without touching the disk (today: an
     `ArgumentError` raise).
2. Rules keeps its key policy where it already is: `Guardian.Rules.Server` filters a
   listing with `RuleSet.parse_key/1` (non-`.gsql` ignored, invalid paths as validation
   errors), `Guardian.Rules.list_rules/1` lists only valid keys, and writes and deletes
   take keys only from `RuleSet.key/2` after `RuleSet.check_path/2`. No new Rules code
   beyond `Guardian.Rules.Store.local?/1` matching the new module (and its moduledoc),
   and `Guardian.Rules.Config` building it and refusing a folder that is or contains
   the data folder, or is inside its segments folder (`Path.expand`, lexical).
3. `Guardian.Rules.Store.Local` is deleted; its local-only tests in
   `test/guardian/rules/store_test.exs` move to `test/guardian/object_store/local_test.exs`
   (listing at depth, dot, non-UTF-8 and temp names skipped, regular files only,
   symlinked file and folder followed, a link back up the tree skipped, the entry cap
   failing the listing, an unreadable file or folder failing it, unsafe keys (empty,
   absolute, `//`, `.`, `..`, `a/../../x`, NUL, dot and temp names, invalid UTF-8)
   refused by get/put/delete with nothing written, ordinary Unicode keys, conditional
   puts, ETags, `age_ms`); the both-stores contract tests move from `store_test` to
   `test/guardian/object_store_test.exs`. `lock_test`,
   `cluster_test` and `config_test` use `Guardian.ObjectStore.Local`;
   `lock_test` no longer depends on Rules. New Rules tests (local folder): `x.gsql` is
   an unattributed error with every table still valid, `t/sub/a.gsql` makes `t`
   invalid, a non-`.gsql` file is ignored and absent from `list_rules`, a write succeeds
   and reports the existing errors while `x.gsql` and `t/sub/a.gsql` exist, and Config
   refuses a rule folder containing the data folder.

## Docs

- `docs/product/spec.md` section 5.1, files item 3: after "listing the store is the
  rule set", add: "Files not ending in `.gsql` are ignored; a `.gsql` file at any other
  path is a validation error, for the table its first folder names if that is a valid
  table. In a local folder, names starting with `.` are skipped."
- `docs/changes/ingest-rules.md` item 2: the `.gsql`-at-invalid-path rule applies to
  both stores.
- `docs/architecture/security.md` invariant 2: Rules' path check, plus
  `Guardian.ObjectStore.Local`'s generic key check, stop escape by key; symlinks inside
  the folder are trusted operator configuration.
- `docs/architecture/system.md` rules section and testing section; the config table if
  it names the module.
- `lib/guardian/CLAUDE.md`, `lib/guardian/object_store/CLAUDE.md` (the new module; rule
  1 notes that Local, unlike S3, refuses unsafe keys), `lib/guardian/rules/CLAUDE.md`
  (the store entry).
- `docs/changes/object-store-lock.md`: the "Not in this change" item points here.
- References to `Guardian.Rules.Store.Local` from the atomic-write-helper change
  (`Guardian.AtomicFile`'s docs, `lib/guardian/CLAUDE.md`, `system.md`).
- TODO.md: close `object-store-local`.

Product spec impact: section 5.1 "Files" item 3 gains the stray-file statement above,
and the configuration reference (and spec, if it lists `GUARDIAN_RULES_DIR`'s rules)
gains the refusal of a rule folder containing the data folder.

## Not in this change

- `Guardian.Rules.Store` then holds only the lock key, lease, save margin and
  `local?/1`; folding it into `Guardian.Rules.Server` is a possible follow-up.
- Exposing `Guardian.ObjectStore.S3`'s 20 s write deadline so the 80 s save margin's
  dependency on it is checked in code, completed in
  [`s3-write-deadline-check.md`](s3-write-deadline-check.md).

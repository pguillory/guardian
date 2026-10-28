# Shared atomic file write

Status: complete.

## Problem

Segment files (`Guardian.Storage.BlobStore.write/2`) and the local rule folder
(`Guardian.Rules.Store.Local`) each wrote a file atomically by writing a temporary
file and renaming it into place, with two implementations. The segment writer
fsynced the temporary file before the rename, used a unique exclusive temporary name
and removed it on failure. The rule folder used a fixed `{path}.tmp` name, did not
fsync, and left the temporary file behind when the rename failed. The mechanism is
generic, so it belongs in a generic layer rather than in Storage or Rules.

## Change

`Guardian.AtomicFile.write/2` is a leaf utility holding the segment writer's
algorithm unchanged: create the parent folder, write a unique `{final}.{n}.tmp`
opened exclusively, fsync, close, rename, and remove its own temporary file on any
failure. `BlobStore.write/2` delegates to it, so Storage's internal boundary and
segment writes are unchanged. The local rule folder writes rule files and the
`_write.lock` object through it, keeping its error mapping.

Durability improvement: local rule and lock writes are now fsynced before the rename.
Before, a host crash or power loss soon after a rule write could leave the renamed
`.gsql` file empty or truncated, because the rename can reach disk before the data.
That lost or corrupted rule content: the table could come up invalid (its events
failing closed) or, since an empty or truncated file can still parse, silently
missing statements. Now a crash leaves the previous version (or no file, for a new
key) or the whole new one, never a torn file. The directory entry is still not
fsynced, so a power loss can roll a recent rule write back that way (system.md
section 4.3, limit 1). The fsync costs one
disk flush per rule write or lock acquire/release, rare administrative operations
off the ingest path; the decision to fsync with no option was the tech lead's.

Other rule-folder effects: the temporary name is now `{key}.{n}.tmp`, a failed write
no longer leaves it behind, and a crash mid-write can leave one. Listing never sees
either name (it matches `_write.lock` exactly and `*/*.gsql`).

## Product spec impact

None in `docs/product/overview.md` or `docs/product/spec.md`: the spec makes no claim
about rule-file durability, and rule writes were and stay atomic. Architecture:
system.md sections 3.4 and 4.3 and `lib/guardian/AGENTS.md` name the helper.
Security architecture: none.

## Validation

Independent Claude and Codex plan reviews approved the leaf home and recommended
fsync with no option. The segment writer's tests moved to
`test/guardian/atomic_file_test.exs`, BlobStore keeps a delegation smoke test, and
`test/guardian/rules/store_test.exs` checks that a local put replaces its file and
that a failed put leaves no temporary file (which the old writer did), and that a
leftover temporary file is never listed.

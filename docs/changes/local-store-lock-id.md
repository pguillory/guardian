# local-store-lock-id: a local folder store serializes its writes

Status: complete.

## Problem

`Guardian.ObjectStore.Local` runs each `put` and `delete` inside a `:global` lock on
this node, so that a conditional put (`:absent` or `{:etag, etag}`) reads the current
file and writes the new one with no other writer in between. A `:global` lock id is
`{ResourceId, LockRequesterId}`, and `:global` grants a held lock again to a process
asking with the same requester. The store passed `{Guardian.ObjectStore.Local, dir}`,
which makes the module the resource and the folder the requester: every process
writing to one folder was the same requester, got the lock at once, and nothing was
serialized. Two concurrent `:absent` puts to one key could both succeed, the second
silently replacing the first. (The one resource was the module, so writers to
different folders on a node did exclude each other.)

`Guardian.ObjectStore.Lock` relies on those conditional puts being atomic, so a lease
lock on a key of a local folder store did not exclude a concurrent contender either.
The practical risk was low, since every rule write goes through the one
`Guardian.Rules.Server` process, but the store is generic.

## Behavior after the change

1. The lock id is `{{Guardian.ObjectStore.Local, dir}, self()}`: the folder is the
   resource and the writing process the requester, so one process at a time writes to
   a folder on this node, as the module documentation already promised. Of
   concurrent conditional puts to one key, exactly one `:absent` put succeeds and the
   others get `{:error, :precondition_failed}`.
2. Scope is unchanged: the lock covers this node only (`[node()]`), and nothing
   coordinates writers on other machines.
3. A contended write now waits. `:global` retries a taken lock after a random sleep of
   up to 250 ms, doubling each time to a cap of 8 s, and does not queue waiters
   fairly, so under sustained contention one write can wait for seconds. Writes to a
   local store are rare (rule edits), so this is acceptable; a node-local queued lock
   would be a separate change. Waiting has no limit, so a hung write holds up later
   writes to its folder; `Guardian.ObjectStore.Lock.acquire/4`'s timeout can be
   overshot while its put waits, which is safe because the lease deadline is taken
   before the put.
4. The lock is keyed by the folder path as configured, so two stores naming one folder
   differently (`dir` and `dir/`, a symlink, a relative path) do not share it. This is
   unchanged. Writers to different folders no longer exclude each other.

## Product spec impact

None. The product spec says nothing about this node-local `:global` lock; the fix
makes the module's documented per-node serialization true.
`lib/guardian/object_store/CLAUDE.md` now says the `:global` lock, not
`Guardian.AtomicFile`, serializes writes.

## Validation

- `test/guardian/object_store/local_test.exs`: four writers to each of five keys,
  released together, each put `:absent`; per key exactly one succeeds, the rest fail
  the precondition, and the file holds the winner's body. It failed three runs out of
  three against the old lock id.

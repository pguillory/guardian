# Object Store Client

The generic client for stores of keyed objects with conditional writes, and the
lease lock built on it. Its design is in `docs/changes/object-store-lock.md`.

Modules:

- `Guardian.ObjectStore`: the behaviour (`list`, `get`, `put` with `:none`, `:absent`
  or `{:etag, etag}`, `delete`, `describe`) and the functions that call a
  `{module, config}` store. A failure is `:not_found`, `:precondition_failed` or a
  message.
- `Guardian.ObjectStore.S3`: the S3-compatible implementation (`req_s3`, R2 or any S3
  API), prefix-scoped, and the endpoint and prefix checks (`check_endpoint/1`,
  `check_prefix/1`) whoever builds a config runs first. Keep only what `req_s3` doesn't
  do.
- `Guardian.ObjectStore.Local`: a local folder, every regular file at any depth an
  object (hidden, non-UTF-8 and `Guardian.AtomicFile` temp names skipped, the walk
  bounded by `max_entries`), with content-hash ETags, writes through
  `Guardian.AtomicFile`, and each folder's writes serialized across connected nodes by
  a `:global` lock held by the writing process, keyed by the folder's device and inode
  (taken in `new/2`) so every spelling of the folder shares it. Contention uses capped
  randomized exponential backoff without fairness or a total wait limit; a hung
  writer blocks later writes, including a lease acquire's put, which waits too.
- `Guardian.ObjectStore.Lock`: a lease lock on one key of any store, judged by the
  store's clock, with ownership-safe release. A lease, not a fence. Acquiring makes one
  attempt and returns `:busy` for a held lock; it never waits or retries, so any retry
  policy is the caller's.

Rules to keep:

1. Generic only. The layer knows nothing about its callers' keys, layouts, limits or
   environment variables; callers (Rules is one, `lib/guardian/rules/AGENTS.md`) pass
   them in. Keep feature policy out, and keep generic store mechanisms out of
   feature modules. `Guardian.ObjectStore.S3` does not validate keys (it encodes each
   path segment, `..` included): key safety is the caller's job. `Guardian.ObjectStore.Local`
   is the exception, since a key is a path on disk: it refuses any key that could
   leave the folder lexically (`..`, absolute) or that `list` would not return;
   symlinks inside the folder are trusted and followed.
2. Never log or return a response body or header from a store call.
3. Every contender for a lock key uses the same lease. The lock cannot fence a holder
   that stalls past its lease or a write applied after the holder gave up.

Tests are in `test/guardian/object_store/`, all on local folders, each at one layer: the
store's functions, or the lock's. S3 mode has no automated test: when this layer
changes, an agent checks it by hand against the real bucket (CONTRIBUTING.md, "Testing
philosophy").

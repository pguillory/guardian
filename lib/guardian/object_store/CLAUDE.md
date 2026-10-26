# Object Store Client

The generic client for stores of keyed objects with conditional writes, and the
lease lock built on it. Its design is in `docs/changes/object-store-lock.md`.

Modules:

- `Guardian.ObjectStore`: the behaviour (`list`, `get`, `put` with `:none`, `:absent`
  or `{:etag, etag}`, `delete`, `describe`, optional `shared?`), the functions that
  call a `{module, config}` store, the failure reasons and `reason_message/1`.
  `shared?/1` reports whether nodes share objects and coordinate conditional writes;
  absent callbacks default to true for existing custom implementations. Local
  returns false, S3 true; callers decide what to permit with that capability.
- `Guardian.ObjectStore.S3`: the S3-compatible implementation (Req with SigV4, R2 or
  any S3 API), prefix-scoped and with a bounded listing (`max_list_pages`), and the
  endpoint and prefix checks (`check_endpoint/1`, `check_prefix/1`) whoever builds a
  config runs first.
- `Guardian.ObjectStore.Local`: a local folder, every regular file at any depth an
  object (hidden, non-UTF-8 and `Guardian.AtomicFile` temp names skipped, the walk
  bounded by `max_entries`), with content-hash ETags, writes through
  `Guardian.AtomicFile`, and each folder's writes serialized on this node by a
  `:global` lock held by the writing process, keyed by the folder's device and inode
  (taken in `new/2`) so every spelling of the folder shares it.
- `Guardian.ObjectStore.Lock`: a lease lock on one key of any store, judged by the
  store's clock, with ownership-safe release. A lease, not a fence.

Rules to keep:

1. Generic only. The layer knows nothing about its callers' keys, layouts, limits or
   environment variables; callers (Rules is one, `lib/guardian/rules/CLAUDE.md`) pass
   them in. Keep feature policy out, and keep generic store mechanisms out of
   feature modules. `Guardian.ObjectStore.S3` does not validate keys (it encodes each
   path segment, `..` included): key safety is the caller's job. `Guardian.ObjectStore.Local`
   is the exception, since a key is a path on disk: it refuses any key that could
   leave the folder lexically (`..`, absolute) or that `list` would not return;
   symlinks inside the folder are trusted and followed.
2. Credentials never leave `Guardian.ObjectStore.S3` and the caller that builds its
   config: they live only in a zero-arity closure, requests carry an MFA for
   signing, and every store call returns a reason naming only a kind. Never log or
   return a response body, header, request, or a caught exception's message from a
   store call.
3. `reason_message/1`'s strings reach API clients through callers; keep them stable.
4. Every contender for a lock key uses the same lease. The lock cannot fence a holder
   that stalls past its lease or a write applied after the holder gave up: callers
   check `remaining_ms/1` against their write's deadline before writing, and leave
   the lock to expire when a write's outcome is unknown.

Tests are in `test/guardian/object_store/` (with the contract both stores share in
`test/guardian/object_store_test.exs`), S3's against `Guardian.FakeS3`, which checks
SigV4 with its own implementation of the canonical request.

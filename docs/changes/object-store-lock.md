# Object store client and key lock

Status: complete.

The rule write lock (`Guardian.Rules.Lock`, the `_write.lock` lease) and the S3 client
(`Guardian.Rules.Store.S3`: SigV4 requests, listing, ETag and date handling, status
mapping) are generic object-store mechanisms living inside the Rules feature. Per
CONTRIBUTING ("generic mechanisms belong in generic layers"), both move to a new
generic object-store client layer, `Guardian.ObjectStore`, and Rules becomes one
caller. The state being changed is the bucket, so the lock lives with the client for
that state, not with Rules or Erlang clustering.

Behavior is unchanged: the same lease semantics and timing (120 s lease judged by the
store's clock, `If-None-Match: *` create, `If-Match` takeover of a released or expired
lock, 500 ms retries for up to 10 s, ownership-safe release, the 80 s save margin and
the unknown-outcome rule), the same requests, timeouts, error reasons and credential
handling. Rules' reread-validate-write flow in `Guardian.Rules.Server` is untouched
apart from the names it calls.

## Layout

New generic layer, `lib/guardian/object_store/` (no Rules references in it):

1. `Guardian.ObjectStore`: the behaviour (`list/get/put/delete/describe`), the
   dispatch functions on `{module, config}`, the reason/condition/meta types and
   `reason_message/1`. Moved from `Guardian.Rules.Store`; doc wording loses its
   rule-specific parts, and `reason_message/1`'s strings (which reach API clients)
   stay byte-identical.
2. `Guardian.ObjectStore.S3`: moved from `Guardian.Rules.Store.S3`. The one
   rule-specific piece, the listing cap (20 pages, because a rule set holds at most
   1,000 files), becomes a struct field `max_list_pages` (default 20, so callers and
   the test fake keep working); `Guardian.Rules.Config` sets it explicitly with the
   rule-set reason. The endpoint and prefix checks that protect the client (an
   `https://` URL with no path, `http://` only for loopback; a prefix ending in `/`
   using only `[A-Za-z0-9._~/-]`) move into `Guardian.ObjectStore.S3` as functions
   returning a reason atom; `Guardian.Rules.Config` maps them to its
   `GUARDIAN_RULES_S3_*` messages, byte-identical to today's. Test-only app env keys rename from `rules_s3_receive_timeout_ms`
   and `rules_s3_write_deadline_ms` to `object_store_s3_receive_timeout_ms` and
   `object_store_s3_write_deadline_ms`. The `Inspect` implementation stays beside the
   struct.
3. `Guardian.ObjectStore.Lock`: moved from `Guardian.Rules.Lock`, generalized to a
   lease lock on any key: `acquire(store, key, holder, opts)` with `:lease_ms`
   (default 120 s) and `:timeout_ms` (default 10 s), `remaining_ms/1`, `release/1`.
   The struct carries its key. Retry interval and body format (`state`, `holder`,
   `token`) are unchanged. Its moduledoc keeps the "lease, not a fence" limits and
   says every contender on a key must use the same lease (the body does not carry
   it), and that checking the remaining lease before a write and handling an unknown
   write outcome are the caller's job.
4. `lib/guardian/object_store/CLAUDE.md` (plus `AGENTS.md` symlink): the layer's
   rules, taking over Rules rule 4 (credentials live only in a closure, requests
   carry an MFA for signing, results name only a kind; never log a body, header,
   request or exception message) and stating that the layer knows nothing about its
   callers' keys.

What stays in Rules (rule policy only):

1. `Guardian.Rules.Store`: the rule store's layout and lock policy. `lock_key/0`
   (`"_write.lock"`), `lock_lease_ms/0` (reads `rules_lock_lease_ms`, 120 s),
   `save_margin_ms/0` (reads `rules_save_margin_ms`, 80 s; documented as depending
   on `Guardian.ObjectStore.S3`'s 20 s write deadline), and `local?/1`. App env
   key names for Rules stay the same.
2. `Guardian.Rules.Store.Local`: stays in Rules for now, now implementing
   `@behaviour Guardian.ObjectStore`. This is a known exception to the CONTRIBUTING
   rule: most of it (atomic temp-and-rename writes, content-hash ETags, serialized
   conditional puts) is generic, but its listing (only `<table>/<name>.gsql` plus the
   lock) and key check (`Guardian.Rules.RuleSet.parse_key/1` or the lock key) are
   rule policy. A generic folder store would list every file in the folder, which
   changes Rules' behavior: a `.gsql` at an invalid path (`x.gsql`, `t/sub/a.gsql`),
   ignored today, would become a validation error for its table, and every stray file
   would be read on each poll to hash it. That change is left for a follow-up
   (below), so this one stays behavior-neutral. As a consequence the lock's folder
   test must use the rule lock key.
3. `Guardian.Rules.Config` builds `Guardian.ObjectStore.S3` (with `max_list_pages`)
   or `Guardian.Rules.Store.Local`.
4. `Guardian.Rules.Server` and `Guardian.Rules` call `Guardian.ObjectStore` for store
   I/O and `Guardian.ObjectStore.Lock.acquire(store, Store.lock_key(), holder,
   lease_ms: Store.lock_lease_ms())`.

## Tests

1. `test/guardian/rules/lock_test.exs` moves to `test/guardian/object_store/lock_test.exs`,
   using two independent arbitrary keys (each acquired and released on its own) and
   a nondefault explicit lease for takeover and `remaining_ms/1`, on FakeS3 and on a local folder
   (`Guardian.Rules.Store.Local`, the only folder implementation; its key must be the
   rule lock key, which the test passes).
2. The S3-only cases of `test/guardian/rules/store_test.exs` (signing, pagination,
   prefix scope, secrets, timeouts and status mapping, date and list parsing) move to
   `test/guardian/object_store/s3_test.exs`, plus one case for `max_list_pages`. The
   both-stores contract test stays in Rules (it covers the rule folder store).
3. Rules keeps its caller-level lock tests in `server_test.exs` (lock taken at
   `Store.lock_key()`, busy when another holder has it, lease margin, unknown outcome
   leaves the lock held), updated to the new names.
4. Every other caller of the old names is updated: `Guardian.Rules` and
   `Guardian.Rules.Server` moduledocs and calls, `config_test` (S3 module and the
   endpoint/prefix messages), `counter_reload_test`, `store_test`,
   `server_test` (store calls and the renamed `object_store_s3_write_deadline_ms`).
   `guardian-namespace.md` is history and stays.
5. `Guardian.FakeS3.store/2` returns a `Guardian.ObjectStore.S3`; namespace_test's
   module list is updated.

## Docs

- `docs/architecture/system.md`: rules section items 6 and 7 name
  `Guardian.ObjectStore.Lock` and `Guardian.ObjectStore.S3`; the config table splits
  the two S3 timeout keys out under `Guardian.ObjectStore.S3`; the testing section
  mentions the object-store tests.
- `docs/changes/ingest-rules.md`: the lock and S3 client items say they are the
  generic object-store client primitives that Rules uses, pointing here.
- `docs/architecture/security.md`: the rule-store credential rows name
  `Guardian.ObjectStore.S3` as the holder of the signing closure where they describe
  it; no behavior change.
- `lib/guardian/CLAUDE.md` gains a `Guardian.ObjectStore` entry; `lib/guardian/rules/CLAUDE.md`
  points to it; root CLAUDE.md lists the new subsystem doc. ARCHITECTURE.md already
  indexes subsystem docs generically.
- TODO.md: this change's entry.

Product spec impact: none. `docs/product/spec.md` describes the lock as "a lease in
the store" without naming modules, which stays true.

## Not in this change

- A generic folder object store (`Guardian.ObjectStore.Local`) with the rule
  listing and key policy moved to the caller. It changes what a local rule folder
  lists and reports (see above), so it is its own change
  (`docs/changes/object-store-local.md`).

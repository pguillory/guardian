# drop-legacy-api-key: only the admin and ingest keys

## Problem

[split-api-keys](split-api-keys.md) introduced the full-access
`GUARDIAN_ADMIN_API_KEY` and the insert-only `GUARDIAN_INGEST_API_KEY`, and kept the
original single key, `GUARDIAN_API_KEY`, deprecated with full access while set, so
callers could move without being refused. That kept a third key in the key check, in
the boot rules, as a `legacy` value of `web_requests.auth_key`, and behind a
rate-limited `/mcp` log line that existed only to show whether it was still used.
The maintainer's deployment retired it on 2026-10-28.

## Change

1. Only two keys exist. `GUARDIAN_ADMIN_API_KEY` is required and has full access;
   `GUARDIAN_INGEST_API_KEY` is optional and insert-only. Each must be nonempty and at
   least 32 bytes, and the two must differ.
2. `GUARDIAN_API_KEY` is no longer read as a key:
   - Without `GUARDIAN_ADMIN_API_KEY`, its presence (any value, even empty) changes
     the boot error to "GUARDIAN_API_KEY is no longer supported; set
     GUARDIAN_ADMIN_API_KEY (full access) and, for clients that only send events,
     GUARDIAN_INGEST_API_KEY; generate each with: openssl rand -hex 32". Without
     either, the error is "GUARDIAN_ADMIN_API_KEY must be set; ...".
   - Beside the admin key it is ignored, not validated, like
     `GUARDIAN_ALLOW_QUERY_API_KEY` after [query-api-key-off](query-api-key-off.md).
     Refusing to boot would turn a leftover secret into an outage for a deployment
     that already has its replacement, and Guardian puts availability first.
3. A request carrying the old key's value gets 401 `unauthorized` like any wrong
   key, unless that value is also configured as one of the two active keys.
4. `web_requests.auth_key` and `web_responses.auth_key` are `ingest` or `admin`;
   rows from older releases may say `legacy`.
5. The `/mcp` log line "A request on /mcp authenticated with the legacy
   GUARDIAN_API_KEY" is gone, and with it the rate-limited note machinery in
   `Guardian.Web.Auth` (its only caller) and the `Guardian.Test.AuthNotes` test
   helper. The application setting `:guardian, :api_key` is no longer read.

## Product spec impact

`docs/product/spec.md`:

- Section 3 item 1: keys are of two kinds, without "plus a deprecated one"; the
  `GUARDIAN_API_KEY` bullet is removed; the admin key is marked required.
- Section 3 item 6: startup requires `GUARDIAN_ADMIN_API_KEY`; the length and
  distinctness rules cover the two keys; a deployment that sets only the removed
  `GUARDIAN_API_KEY` gets an error naming the two replacements, and beside the admin
  key it is ignored.
- Section 3 item 7: `auth_key` is `ingest` or `admin` (older rows may say `legacy`);
  the MCP log line and "whether the deprecated key is still in use" are removed; the
  forged-row caveat stays.
- Section 8 item 2: `auth_key` is `ingest` or `admin`, `legacy` in older rows.

`docs/product/overview.md`, "How it behaves" item 1: the sentence about the deprecated
key is removed.

## Validation

- `test/guardian/config/runtime_test.exs`: the admin key alone boots; no admin key is
  refused, with or without the ingest key; only `GUARDIAN_API_KEY` set (valid, empty
  or short, with or without the ingest key) gives the error naming both
  replacements; beside the admin key it is ignored whatever its value, including one
  equal to an active key; length, emptiness and distinctness for the two keys.
- `test/guardian/web/auth_test.exs` and `auth_routes_test.exs`: a value configured
  under the old `:api_key` setting is refused with 401 on both routers.
- `test/guardian/web/json_api_test.exs` and `logger_test.exs`: `auth_key` rows are
  `admin` or `ingest`.
- Tests that used the old test key as their working full-access key use the admin
  key.

## Deploy notes

Before deploying, confirm by name that `GUARDIAN_API_KEY` is not the deployment's
only key (`fly secrets list`; never print values). If it is, set
`GUARDIAN_ADMIN_API_KEY` first, or the new release refuses to start. After deploying,
check `GET /health`, a 401 without a key, an MCP query with the admin key, and a 403
for the ingest key on `/mcp`. Don't inject test events.

Rollback: the previous release accepts the two new keys, so rolling back needs
nothing as long as `GUARDIAN_API_KEY` is unset: that release reads it again, giving a
stale value full access, or refusing to start if it is short or equal to another key. Rolling back past split-api-keys needs `GUARDIAN_API_KEY` set again and
callers moved back to it.

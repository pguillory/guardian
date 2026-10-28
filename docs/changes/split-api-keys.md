# split-api-keys: an insert-only key, a full-access key, and HTTP for ingestion only

## Problem

Guardian had one API key, and it granted everything: queries over HTTP and MCP, rule
changes and ingestion. Applications that only send events held that key, so a
compromised application could read every table and rewrite the rules that run on
every ingested event.

## Change

1. Two keys with different scopes, each in its own environment variable:
   - `GUARDIAN_INGEST_API_KEY` is insert-only. `POST /api/json/send_events` accepts
     it; every other request gets 403 `this key can only send events`, before its
     body is read.
   - `GUARDIAN_ADMIN_API_KEY` has full access: `/mcp` (queries, rules, ingestion) and
     `send_events`.
2. `GUARDIAN_API_KEY` is kept, deprecated, with full access while it is set, so every
   caller keeps working while it moves to a new key. Retiring it is a separate
   operator step (Deploy notes); a later change, drop-legacy-api-key, removes its
   support.
3. `POST /api/json/query` is removed. `send_events` is the only JSON endpoint, and
   queries and rules go through MCP, which was already the main query interface.
   With a full-access key the old path is a 404 like any unknown path.
4. Boot requires at least one full-access key (`GUARDIAN_ADMIN_API_KEY` or
   `GUARDIAN_API_KEY`). Each of the three variables, when set, must be nonempty and at
   least 32 bytes, and no two may share a value (a shared value would give the ingest
   key full access). Errors name the variable, never the value.
5. `web_requests` and `web_responses` record `auth_key` (`ingest`, `admin` or
   `legacy`) beside `auth_method`, never the key. MCP requests are not recorded
   there, so `/mcp` logs one line, at most once a minute per node, when a request
   uses the deprecated key, like the existing note for query-parameter keys. Each
   note has its own rate limit.

How it is enforced: `Guardian.Web.Auth.check_conn/2` takes the access a request
needs. The JSON API asks for ingest access only for `POST /send_events` and full
access for everything else, so a JSON route added later is full-access unless it
opts in. `/mcp` asks for full access on every request, before the session check and
body decoding. `Guardian.Web.Auth.identify_api_key/1` compares the supplied key with
every configured key in constant time, without an early return, so timing reveals
neither how much of a guess is right nor which key matched.

What the ingest key can still do, unchanged ingestion semantics documented in the
security architecture: `return_keys` returns stored events after rules, so a `TRACK`
or `LOOKUP` rule lets it read counter values for keys it chooses; it can write any
valid table, including Guardian's built-in tables, and so append forged rows
(including `web_requests` rows with any `auth_key`), though it cannot hide or delete
real ones; it can create tables and send 8 MB bodies like any key. The boundary is
no queries and no rule access, not no reads at all. reserve-builtin-tables is the
follow-up that would close the forged-row path.

Out of scope: per-table permissions, several keys per kind, identities, and
`GUARDIAN_ALLOW_QUERY_API_KEY`, which is unchanged and applies to all three keys.

## Product spec impact

`docs/product/spec.md`:

- Section 1, design commitment 1: "One API key, full access, no identities" becomes
  no identities, a full-access key and an insert-only key.
- Section 2: producers normally hold the ingest key; readers item 2 ("Scripts use the
  JSON query endpoint") says there is no HTTP query endpoint; the built-in table list
  says `queries` and `query_parse_errors` come from MCP.
- Section 3: item 1 describes the two keys and the deprecated one; item 2 says what
  the ingest key can and cannot do; item 3 says each key rotates independently;
  item 5 adds the 403; item 6 gives the new startup rules; item 7 adds `auth_key` and
  the deprecated-key log line, and says these are evidence, not proof.
- Section 4.1: the `POST /api/json/query` subsection is replaced by a note that
  `send_events` is the only JSON endpoint; unknown paths are 403 with the ingest key.
  Section 4.2: MCP needs a full-access key.
- Section 8: `web_requests` gains `auth_key`; `query_parse_errors` and `queries` are
  written for MCP queries only, `interface` is `mcp` (older rows may say `http`).
- Section 12: the known gap "JSON query errors are a bare 500" is gone with the
  endpoint, and the list is renumbered.

`docs/product/overview.md`: the paragraph's "One API key grants access to
everything", the readers item (scripts used the JSON API) and trust item 1 describe
the two keys and the deprecated one.

## Validation

- `test/guardian/web/auth_test.exs` and `auth_routes_test.exs`: every key against
  both routers and every credential form, including the 403 bodies, an ingest key on
  an existing MCP session, and the deprecated-key log line.
- `test/guardian/web/json_api_test.exs`: every key can send events; the ingest key
  gets 403 on every other JSON path and method without its body being read; the old
  query path is 404 with a full-access key; `web_requests` records `auth_key`. The
  authentication, body-limit and listener tests that used the query endpoint now use
  `send_events`.
- `test/guardian/config/runtime_test.exs`: the boot rules above.
- The query-recording tests run through `Guardian.Web.Query.execute/3`, the MCP
  tool's runner; JSON query resolution tests moved to `test/guardian/web/query_test.exs`.
  Two tests of the JSON failure boundary that used a query parse error as their
  trigger were removed with the endpoint; the boundary keeps its direct tests.

## Deploy notes

Generate each key with `openssl rand -hex 32`. Commands below use placeholders; never
paste real values into files or logs. No caller may be refused at any step:

1. Stage both new secrets without restarting the running release, which ignores them:
   `fly secrets set --stage GUARDIAN_INGEST_API_KEY=<ingest-key> GUARDIAN_ADMIN_API_KEY=<admin-key>`
2. Deploy (separately authorized). `GUARDIAN_API_KEY` still has full access. Check
   `GET /health`, a 401 without a key, an MCP query with the admin key and with the
   old key, and a 403 for the ingest key on `/mcp`. Don't inject test events.
3. Move every insert-only client (one that only calls `send_events`) to the ingest
   key, and every MCP client to the admin key.
4. Confirm the inventory of clients by hand, then watch for a while:
   `SELECT auth_key, count() FROM web_requests WHERE timestamp > date_sub(now(), INTERVAL 1 DAY) GROUP BY auth_key`
   should show no `legacy`, and the server log should show no "authenticated with the
   legacy GUARDIAN_API_KEY" line. A quiet period is evidence, not proof: an idle
   client leaves no trace.
5. Retire the old key, a separate and irreversible step taken only once every client
   has moved: `fly secrets unset GUARDIAN_API_KEY` (this restarts the machines; any
   client still using it is refused from then on).

Rollback: once a client uses a new key, a release without this change refuses it,
since older releases know only `GUARDIAN_API_KEY`. Move those clients back to the old
key before rolling back past this release.

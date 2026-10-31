# Guardian security architecture

This document argues, boundary by boundary, that Guardian protects what it claims to
protect, and states plainly where it does not.

It builds on the product spec. [spec.md section 3](../product/spec.md#3-access-and-trust)
says what a caller can observe about access and trust; this document says how that is
enforced and what the spec leaves to the implementation. How the system is built in
general (supervision tree, storage lifecycle, query pipeline, clustering mechanics) is
the [system architecture](system.md).

Fly.io is the best-supported deployment, and several boundaries below describe it
concretely. Guardian also runs as a single node or as a cluster on any set of
machines; where the argument depends on the deployment, the text says which. Section
9 lists the known gaps together.

## 1. What is being protected

Assets, roughly in order of value:

1. Event data: every table on every node's data directory, including the built-in
   tables. Producers send whatever the operator's systems choose to record (spec
   section 2). Event content is not classified; treat it as the operator's private
   data.
2. Caller query text: by design kept for every query run over MCP (the only query
   interface), in `queries`, and for queries that fail to parse, in
   `query_parse_errors`, for the 15-day retention period (and in any backup or volume
   snapshot for as long as that is kept, section 7). Logs are not scrubbed, so a crash
   report or Anubis's timeout line can print it too (section 8).
3. The API keys, the only credentials for the HTTP and MCP interfaces: the full-access
   admin key (`GUARDIAN_ADMIN_API_KEY`), the insert-only ingest key
   (`GUARDIAN_INGEST_API_KEY`).
4. The Erlang cookie (`RELEASE_COOKIE`): grants full code execution on every node to
   any Erlang node that can reach the nodes' distribution ports.
5. Availability and integrity of recent events: events not yet persisted live only in
   memory. A table's in-memory segment is handed off for persistence after one hour by
   default (spec section 9), and queue or disk delays can stretch the time to disk
   beyond that, so anything that kills the VM without a graceful stop loses every event
   not yet on disk: by default up to the last hour of each table, longer when
   persistence is backed up.

Principals:

1. Full-access key holder: anyone presenting the admin key.
   Guardian is single-tenant (spec section 3): every full-access key holder is the
   same principal with full read and write access. In practice that is the operator
   and their agents and scripts.
2. Ingest key holder: anyone presenting the ingest key, in practice the operator's
   producers. It can send events and nothing else on the API; what that still lets it
   read and write is in section 4.6.
3. Operator: whoever holds the deployment. On Fly, that is every member of the Fly
   organization that owns the app; elsewhere, whoever administers the machines, their
   environment, and their disks. Operators hold everything: secrets, shell, data,
   logs.
4. Peer node: another Guardian node that holds the cookie and can reach this one
   (section 6).
5. Anonymous network client: anyone who can reach the HTTP port, on Fly anyone on the
   internet.

Out of scope: the hosting platform (on Fly, its edge, hypervisor, private network,
secret store, and snapshot storage are trusted; elsewhere, the operator's hosts and
network), the build toolchain and Hex dependencies (pinned in `mix.lock`; see the
[dependency pins](system.md#104-dependency-pins)), and callers' own handling of their keys.

## 2. Boundaries at a glance

```text
 network client                         the operator's Cloudflare Workers
        |  B1: TLS at the deployment's         |  B1b: optional Cloudflare Tunnel,
        |      edge (on Fly, Fly's proxy),     |       opened outbound by cloudflared
        |      HTTP to the node                v       on the node
        v
 Bandit HTTP server (GUARDIAN_PORT, default 8080)  -- GET /health, CORS preflight
        |  B2: API key check and scope (x-api-key header only; the ingest key
        |      reaches only send_events)
        v
 key holder: JSON API send_events (any key), MCP server (full-access key)
        |  B3: query engine and ingestion (one principal; availability limits)
        v
 Storage in the node's data directory  -- B6: data at rest, retention, backups
        |
        +-- B4: Erlang distribution to peer nodes (cookie, private network)
        +-- B7: logs (stdout, built-in tables)

 operator -- B5: deployment access: secrets, shell, remote console, data, logs
```

Each section below states what the boundary must guarantee, the invariants that carry
the guarantee, the argument that each invariant holds, and the gaps.

## 3. B1: Network edge

Guarantee: clients reach Guardian only on the routes Guardian chooses to serve, over
TLS supplied by the deployment; and, when the tunnel is configured, through
Cloudflare's network from the operator's Workers VPC binding (invariant 6).

Guardian itself speaks plain HTTP on `GUARDIAN_PORT` (default 8080) and has no TLS of
its own. TLS, and any edge controls, come from whatever the operator puts in front of
it: on Fly, Fly's proxy; elsewhere, a reverse proxy or load balancer. A deployment
that exposes the port directly beyond the machine sends the key in clear.

Invariants and argument:

1. Routes: `Guardian.Web.MainRouter` serves `GET /health`, forwards `/api/json` to
   `Guardian.Web.JsonApi` and `/mcp` to `Guardian.Web.MCP.Router`, and answers 404 to everything else.
2. On Fly, only the HTTP service is public. The `fly.toml` that `fly launch` writes in the Fly guide has one `[http_service]`
   (internal port 8080) and no other services, so Fly's edge forwards only HTTP and
   HTTPS on the app's public addresses. Erlang distribution ports and epmd are not
   published; they are reachable only on Fly's private network (section 6).
3. On Fly, TLS terminates at Fly's edge. `force_https = true` makes the edge redirect
   plain HTTP to HTTPS. From the edge to the machine, traffic is plain HTTP on Fly's
   internal network, which is out of scope here.
4. On Fly, the Fly guide sets no concurrency limit, so Fly's defaults apply: a soft
   limit of 20 connections per machine, past which the edge prefers other machines, and
   no hard limit. Nothing at the edge bounds a machine's concurrent requests; an
   operator who wants a bound sets `hard_limit` under `[http_service.concurrency]`.
5. Elsewhere, the equivalents of invariants 2 to 4 are the operator's: which ports the
   host exposes, where TLS terminates, and whether anything bounds concurrency. Section
   6.3 covers the distribution ports.
6. A second way in, B1b: when the `TUNNEL_TOKEN` secret is set, `bin/fly-start` (the
   image's entry point) runs a cloudflared connector beside Guardian. It opens outbound
   connections to Cloudflare and forwards requests that the operator's Cloudflare
   Workers send through a Workers VPC binding to `127.0.0.1:8080`, as plain HTTP inside
   the machine (Cloudflare encrypts the hop to the connector). No public hostname or DNS
   record needs to point at it: Cloudflare routes only requests made through Workers
   VPC in the operator's Cloudflare account, to the VPC services configured there. The
   connector itself limits nothing (gap 4). The same routes and the same API keys (B2)
   apply. Fly's edge controls do not: no `force_https` redirect, no edge TLS, and any
   edge concurrency limit doesn't count this traffic. Such requests reach
   Guardian from `127.0.0.1`, so `web_requests.remote_ip` shows that, not the Worker.
   The script starts the connector only once Guardian listens and stops it before
   Guardian on shutdown, and `GUARDIAN_TUNNEL=off` keeps it from starting at all; in
   every case the token is unset before Guardian starts.

Gaps:

1. On Fly, the redirect does not protect a client configured with `http://`: its first
   request, key included, crosses the internet in clear before the redirect. No HSTS
   header is sent. This is a client configuration risk; the product could reject
   instead of redirect, but does not.
2. Bandit listens on every IPv4 interface of the machine (`Guardian.Web.init/1` passes no
   `:ip`, so Bandit's IPv4 default applies). On Fly, whose private network is
   IPv6-only, the port is probably not reachable there, bypassing the edge; this was
   not verified. Elsewhere, the port is reachable from any network that reaches the
   host unless the operator firewalls it. Either way the key is still required (B2),
   but that traffic skips the edge's TLS and any edge concurrency limit.
3. Anyone holding the tunnel token can run their own connector for the same tunnel,
   and Cloudflare may then send them some of the Workers' requests, API key included.
   The token is therefore kept like the API keys: a secret, never logged
   (cloudflared doesn't print it).
4. The connector has no destination allowlist (read from cloudflared's source and
   docs, not tested). Anyone with suitable rights in the operator's Cloudflare account
   can add VPC services or a VPC network on this tunnel and reach whatever cloudflared
   can: epmd and Erlang distribution on this machine (cookie-gated, B4), cloudflared's
   own metrics listener (pinned to `127.0.0.1:20241`; its diagnostics over the
   management service are off), and, on Fly, other apps on the organization's private
   network. The tunnel makes administrative access to that Cloudflare account a
   foothold inside the deployment's private network. Acceptable when the same operator
   administers the Cloudflare account and the deployment; an iptables owner match on
   the connector would close it.

## 4. B2: API keys

Guarantee (spec section 3): no event data is read or written without a key, and the
ingest key reaches only `POST /api/json/send_events`: no query, no rule read or
change, no MCP (section 4.6 says what it can still do through ingestion). Besides
401s, 403s and 404s, the only responses the application serves without a key are
`GET /health` and CORS preflight answers. The query string is never decoded before
the key check, so a request without the header is 401 whatever its query string.
None of these reads or writes data.

### 4.1 Where the keys live

1. In the environment: on Fly, Fly secrets injected into the machine's environment
   at boot; elsewhere, however the operator sets the process environment.
   `config/runtime.exs` reads `GUARDIAN_INGEST_API_KEY` (optional) and
   `GUARDIAN_ADMIN_API_KEY` (required), and refuses to start if a set one is empty or
   shorter than 32 bytes, if the admin key is not set, or if the two are equal (a
   shared value would give the ingest key full access). Its errors name the variable,
   never the value. The removed `GUARDIAN_API_KEY` is not read: without the admin key
   its presence changes the error to one naming the two replacements, and beside the
   admin key it is ignored. It stores the keys in the application environment
   (`:guardian, :ingest_api_key`, `:admin_api_key`), nil when unset.
   One exception: a local Mix run in dev without the admin key generates a random
   one and prints it to stderr, the only place Guardian prints a key, so the
   developer can use it. A release cannot take this path: `config_env()` is fixed
   at build time, `mix.exs` refuses to build a release outside `MIX_ENV=prod`, and
   the branch also requires Mix, which a release lacks.
2. Tests use fixed keys in `config/config.exs`; they protect nothing.
3. Guardian does not record a key itself (both routers drop every `x-api-key` header
   once the key passes, so no later plug or handler, Anubis included, receives it;
   see 4.2): the `x-api-key` header is not in
   `web_requests` (which records `path`, the request path without the query string,
   selected headers, and `auth_key`, which says only which key it was: `ingest` or
   `admin`; older rows may say `legacy`), not in
   `query_parse_errors` (caller fields are remote IP, `x-forwarded-for`, user agent,
   and MCP client info), not in `queries` (remote IP and MCP client info only, no
   request header), and not in any log line of a well-formed request found in the
   code (section 8). One exception: `web_requests` stores the `referer` header
   verbatim, so a caller whose referring URL contains `?api_key=` gets the key
   recorded there.

### 4.2 How the keys are checked

Both routers call `Guardian.Web.Auth.check_conn/2`, the one place a key is found and
checked, with the access the request needs: `:ingest` or `:full`. It reads only the
first `x-api-key` header and never decodes the query string, so a key in the URL is
never accepted, and an undecodable query string cannot fail authentication. A valid
key with enough access returns `{:ok, key}`, `key` being `:ingest` or `:admin`, which
one it was. The ingest key where `:full` is needed is
`{:error, :forbidden}`, which each router answers with 403 `this key can only send
events`. No header is `{:error, :missing}`, whatever the query string; a wrong key is
`{:error, :unauthorized}`. Each router sends its own body for these, pinned for each
credential form by `test/guardian/web/auth_routes_test.exs`. Once the key passes, each
router drops every `x-api-key` header with `Guardian.Web.Auth.drop_api_key/1`. That
changes only the conn passed on: Bandit's own conn still holds the key and is attached
to its error-report metadata, which Guardian's logger configuration does not print
(`test/guardian/config/config_test.exs` fails if `config/config.exs` gives production a
formatter or handler), and the JSON API's failure boundary answers with the conn it was
called with.
`Guardian.Web.Auth.identify_api_key/1` compares the supplied key with every
configured key, each with `byte_size(supplied) == byte_size(configured)` and
`Plug.Crypto.secure_compare(supplied, configured)`, with no early return, and returns
`{:ok, key}` or `{:error, :unauthorized}`. Boot guarantees the configured keys are
distinct, so at most one matches. A value that is not a string is rejected like a
wrong key, with nothing printed.

Which access a request needs is decided per route. The JSON API asks for `:ingest`
only for `POST /send_events` (`required_access/1` in `Guardian.Web.JsonApi`); every
other path and method, including unknown ones and any route added later, needs
`:full`. The MCP router asks for `:full` on every request.

Argument: `secure_compare` examines every byte of equal-length inputs regardless of
where they differ, and every configured key is compared whatever the earlier results,
so response timing reveals neither how much of a guess is correct nor which key
matched. The comparison is exact bytes: no trimming, case folding, or decoding beyond
what Bandit and Plug do to headers and query strings (Bandit drops leading and trailing
whitespace from HTTP/1 header values). Scope is checked only after a key is
identified, so a 403 tells the caller nothing it did not already know: it holds the
ingest key.

Gaps:

1. Length is observable. The explicit size check (and `secure_compare`'s own) returns
   faster for a wrong length than for a wrong value. This reveals only the keys'
   lengths, which matter little for long random keys.
2. The minimum is a length policy, not an entropy check. Startup refuses a key shorter
   than 32 bytes, but a long guessable key passes. The docs and the startup error
   say to generate one with `openssl rand -hex 32`; nothing checks that it was.
3. Keys never travel in URLs: only the header is read, since URLs end up in
   client-side logs, shell history, proxy logs, and browser history more readily
   than headers. Guardian does not store request URLs (only the `referer` header,
   item 4.1.3). Because of CORS (section 4.4), a browser page cannot send the key at
   all, so Guardian has no browser clients.
4. Failed attempts leave no trace. A request with a wrong or missing key is rejected
   with 401, and the ingest key outside `send_events` with 403, before
   `Guardian.Web.Logger` runs (JSON API) or before Anubis sees it (MCP), and nothing
   is written to stdout. There is no rate limit, lockout, or alert, so
   guessing is invisible. With a long random key guessing is infeasible; with a weak
   key it would be both feasible and unseen.

### 4.3 The two authenticated surfaces

JSON API (`Guardian.Web.JsonApi`), plug order:

1. `CORSPlug`: adds CORS headers; answers a preflight (`OPTIONS` with
   `Access-Control-Request-Method`) with 204 and halts.
2. `:auth`: the key check, with `:ingest` for `POST /send_events` and `:full` for
   everything else; 401 (or 403 for the ingest key) and halt on failure. It reads only
   the method, path and headers. It records which key it was for
   `Guardian.Web.Logger` and drops every `x-api-key` header.
3. `Plug.Parsers` (JSON only, Plug's default 8 MB body limit): reads and decodes the
   body. Failures get 400, 413, or 415 with a fixed message and are not printed.
4. `:match`, `Guardian.Web.Logger`, `:dispatch`. `POST /send_events` is the only
   route; anything else is 404 (with a full-access key; the ingest key got 403 at
   `:auth`). The former `POST /query` is one of those unknown paths.

MCP (`Guardian.Web.MCP.Router`), plug order:

1. `:auth`: the key check, first, requiring `:full`: the ingest key gets 403 on every
   request, including one on an existing session.
2. `:reject_unknown_session` (404), `:reject_get` (405).
3. `:decode_body` (POST): reads up to 8 MB (413 above) and decodes it as one valid
   JSON-RPC message; anything else gets 400 with a JSON-RPC error and no log line.
4. `:require_session` (404 for a POST other than initialize or `server/discover` that
   names no session; a session-less `server/discover` probe gets 200 with JSON-RPC
   error -32601 and starts no session), `:drop_protocol_version`, `:answer_inline`
   (Accept set to `application/json`).
5. Forward to Anubis's Streamable HTTP plug with the decoded body, so Anubis neither
   reads nor decodes it.

Argument that no data moves without a key: every handler that touches Storage, the
query engine or the rules (`/send_events` and the MCP tool and resource handlers)
sits behind `:auth` in its router's pipeline, and a plug that halts stops the
pipeline. The query engine and the rule tools are reachable only through MCP, which
requires `:full`, so the ingest key reaches only `send_events`.
CORSPlug's preflight answer runs before `:auth` but calls no handler and reads no
body.
MCP sessions carry no authority of their own: every request, including one naming an
existing session ID, passes `:auth` again, so a leaked session ID is useless without
a full-access key, and rotating a key takes effect on the next request after the
restart that loads it.

The JSON API checks the key before reading the body, so an anonymous client cannot
make the server allocate memory and CPU to parse up to 8 MB of JSON per request. Tests
show a request without a valid key gets 401 with its body unread, including a 9 MB
body. The ingest key on a full-access path is refused at the same plug, so its body
is not read either. Any key holder,
the ingest key included, can still send 8 MB bodies to `send_events`, which is the
product's ingestion limit.

Ingest idempotency metadata is claimed only after authentication and shared request
validation. The key is a nonempty UTF-8 body/tool string of at most 128 bytes,
scoped to a table on this node, and is not a credential. The coordinator holds at
most 10,000 independent copies of bounded keys/table names, SHA-256 request digests,
tokens/monitors, status/count and expiry, never payloads or response events. Its
state is not redacted, so a crash report can show idempotency keys. Operator
debug tracing and raw process inspection still have the same full-memory authority
as a remote shell. No keys/digests/events appear in its conflict messages, and
fail-open operation logs nothing. Capacity evicts completed entries; if all are pending
or the coordinator fails or times out, valid ingestion proceeds unprotected. This protects
availability at the cost of possible duplicate writes. Restart, expiry and retries
on another node also lose protection; receipts are not a durability guarantee.

### 4.4 CORS

CORSPlug runs with its defaults on `/api/json` only (not `/mcp`): any origin
(`Access-Control-Allow-Origin: *`), methods GET, POST, PUT, PATCH, DELETE, OPTIONS,
a fixed allowed-header list that does not include `x-api-key`, and a 20-day preflight
cache. It also sends `Access-Control-Allow-Credentials: true`, which browsers ignore
alongside a `*` origin.

Argument that open CORS is safe here: Guardian has no cookies or other ambient
credentials, so a hostile page cannot borrow a visitor's authority; it can only send
requests carrying a key it already knows. Open CORS lets pages read responses, which
matters only if the page holds the key.

Side effect: a browser page cannot send `x-api-key` cross-origin, and a key in the URL
is not accepted, so a browser page cannot call the authenticated routes (4.2.3).

### 4.5 Unauthenticated responses

1. `GET /health` returns `200 ok`, reads no data, and is served only after Storage
   has loaded (the HTTP listener starts after Storage in the supervision tree). While
   Storage restarts it returns `503 storage unavailable`, which reveals only that.
2. Preflight 204s carry CORS headers only.
3. 401 bodies distinguish "api_key required" from "unauthorized", which reveals only
   whether a key was sent.
4. Unknown paths answer 404 without revealing whether they would exist with a key,
   except that `/api/json/*` and `/mcp` answer 401 without a key where other paths
   answer 404 (and the ingest key gets 403 on any of them but
   `POST /api/json/send_events`). The route list is public in the spec anyway.

### 4.6 What the ingest key can still do

The ingest key's boundary is "no queries, no rule reads or changes", not "no reads at
all" (an invalid table's event errors quote a little of its rules: 5.2, item 8). Through `send_events` it can:

1. Read what ingestion returns. `return_keys` gives back columns of each stored row
   after the table's rules, so a `TRACK` or `LOOKUP` rule lets the ingest key read the
   counter value for any key it chooses to send (and a SET rule's computed fields). This is
   the product's decision path (spec section 5.1) and cannot be withheld from
   producers without breaking it.
2. Write any valid table name, including Guardian's built-in tables (`queries`,
   `query_parse_errors`, `web_requests`, `web_responses`, `system_stats`), since
   those take ingestion like any other table. It can append forged rows, including
   rows with a forged `auth_key`, but it cannot hide, change or
   delete real rows, and it cannot read any table back. Treat built-in rows as
   evidence a key holder could have forged.
3. Create new tables and send 8 MB bodies, like any key, within the ingestion limits
   of section 5.

Gaps:

1. Counter values are readable through `return_keys` by the ingest key (item 1).
2. Built-in tables accept forged rows from the ingest key, so `web_requests.auth_key`
   and the other audit-like rows are not proof (item 2).
3. Rolling Guardian back to a release from before the admin and ingest keys refuses
   every caller, since those releases know only `GUARDIAN_API_KEY`, which current
   releases no longer read. Rolling back that far means setting that key again and
   moving callers to it first.

## 5. B3: Key holder to query engine and storage

Guarantee: there is no confidentiality boundary here, because every full-access key
holder is the same principal with full access (spec section 3); the ingest key
reaches this boundary only through ingestion (4.6). What this boundary must guarantee
is that a key holder cannot exceed the product's interface: no code execution, no file
access outside segment files, no reading process secrets, no writes beyond ingestion,
and no single request that takes the service down or destroys stored data.

### 5.1 What holds

1. Read-only SQL. The parser and planner implement SELECT, SHOW TABLES, DESC, and LET
   only; there is no INSERT, UPDATE, DELETE, or DDL (spec section 7). Writes happen
   only through `send_events`, which goes through `Guardian.Engine`, and, for rule files, the
   MCP rule tools, which go through `Guardian.Rules` (item 7).
2. No path or atom injection from names. Table names must match
   `[a-z_][a-z0-9_]*` and avoid reserved words (`Guardian.Engine.valid_table_name?/1`), checked
   before any write; segment filenames are built only from a validated table name and
   a generated segment ID, so a table name cannot escape `segments/`. Table names are
   at most 64 bytes, which keeps a segment's temporary filename
   (`{table}.{32-character id}.seg.{n}.tmp`) inside the filesystem's 255-byte name
   limit. Queries do not open segment files by table name: they look up tables already
   registered in memory. Nothing in `lib/` converts caller strings to atoms
   (`String.to_atom` and friends do not appear), so the atom table cannot be exhausted
   from input. Compiled rule modules take their names from a fixed pool of 1,024
   (`Guardian.Rules.Compiler`), never from a table name or rule text, so editing rules any
   number of times creates no new atoms. Rule file paths are checked
   (`Guardian.Rules.RuleSet.check_path/2`: a valid table name and `[a-z0-9_][a-z0-9_-]*`)
   before they reach the store, and the folder store (`Guardian.ObjectStore.Local`)
   refuses any key that is not a plain relative path (no empty, `.` or `..` segment,
   no leading `.`, no NUL, valid UTF-8), so no key can climb out of the rule folder.
   Symlinks inside the folder are followed, by listings, reads and writes alike: they
   are the folder owner's configuration, trusted like the folder itself.
3. No dynamic code from input. Nothing in `lib/` evaluates code, runs shell
   commands, or decodes Erlang terms from input (`Code.eval`, `System.cmd`, `:os.cmd`,
   and `binary_to_term` do not appear). Rules are compiled with `Module.create/3`, but
   the module body is a fixed template (`Guardian.Rules.Compiler`): one `Guardian.Rules.Runtime.run/3`
   call receives ordered typed steps with parsed ASTs as escaped literals, which the
   query engine's scalar evaluator interprets as it does query expressions. No rule
   text becomes code, and rules can call only the registered scalar functions.
4. Value validation. `Guardian.Engine` drops values the column NIF cannot store (out-of-range
   integers, over-deep lists, oversized strings and lists, keys over 250 bytes) before
   they reach native code (spec section 5).
5. Query parse failures are recorded asynchronously and with fixed bounds (16 KiB SQL,
   1 KiB error, 256-byte caller fields, 60 rows per machine per hour, queue cap 100), so
   a flood of bad queries cannot grow that table or delay responses without limit
   (`Guardian.Web.QueryParseErrors`). Every API query is recorded the same way in `queries`
   (`Guardian.Web.QueryLog`): 16 KiB SQL, 1 KiB error, 256-byte caller fields, queue cap 1,000
   rows, and no rate cap, since each query writes one row whose cost is of the order
   of the query's own.
6. A segment the persister cannot store (for any reason, such as a full disk) is
   logged once, stays in memory and queryable, and is retried on every pass while
   other segments persist, so one bad segment does not stall persistence.
7. Rules are a key holder's power over ingestion, the same principal's. A rule can set
   or remove any field of any event sent through the ingest APIs to its table, on any
   table name, but cannot query stored event data. Rules run on API-ingested rows;
   Guardian's own writes to its built-in tables never run rules. SET/UNSET
   are stateless; TRACK/LOOKUP keep ephemeral counter state and can read a named
   counter on another table through bounded calls to Guardian peers, never an
   external runtime service.
   Each event's rules run in a worker with the query heap limit and a 1-second
   limit, outside the request process (for MCP, the request's task and its send_events worker). A
   kill fails only that event and tells the sender; nothing is logged, and heap kills skip
   the error_logger report. A statement that raises crashes the
   worker and fails the whole request with a 500, and that failure's log lines can
   show event values, such as a password an UNSET was meant to remove. Either way
   rules fail closed (not stored), so a broken `UNSET password` does
   not store the password.
8. The rule store is read at boot, on writes and on reload, never per event, so
   the ingest path makes no rule-store/external-service calls (counter peer RPCs
   stay inside Guardian). Its S3 credentials stay out of
   application config and error messages, though the server's state, so a crash report,
   can show them (7.2). The S3 endpoint must use
   `https://` unless it is on the same machine (`localhost`, 127.0.0.0/8 or
   `[::1]`; `Guardian.Rules.Config` refuses anything else at startup, with the
   object-store client's check, `Guardian.ObjectStore.S3.check_endpoint/1`), so no one on the
   network path can read rule text or rewrite the rules a node loads. The name
   `localhost` relies on the machine's own resolver mapping it to loopback.
9. Counter storage: `Guardian.Counters.Store` owns one public ETS table, accessible
   directly by trusted code in this VM, with a 64 MiB default asynchronous memory
   target (`GUARDIAN_COUNTER_MEMORY_MB`, positive integer MiB; explicit empty/invalid
   refuses startup). No HTTP access is added. Housekeeping conservatively charges
   serialized encoded keys/values, backing allocations retained by nested value
   binaries/bitstrings and ETS memory. Encoding copies keys, detaching key slices.
   Fixed empty/descriptor overhead, mailboxes and temporary copies are excluded.
   Writes can exceed the target between sweeps and during concurrent reclamation;
   individual oversized payloads are refused. About every second, bulk expiry
   reclamation precedes sampled earliest-expiry cutoff eviction. Tied expiries may
   discard every live bucket. Operations never run housekeeping; reads check expiry,
   incr retains insertion expiry, add and cas set it, and expired-key reuse has bounded conditional
   cleanup. Operations have local deadlines and fixed errors; formatted status is
   not redacted.
   Whole-set preparation validates counter semantics and resolves identities without
   evaluating expressions or accessing counter state. Compiler refuses unresolved
   plans and unbound LOOKUPs. Live counter execution uses the resolved-step
   dispatcher: an unreachable store's failures overwrite the output
   with aggregate defaults and continue, so final UNSETs still remove secrets;
   anything that raises fails closed. Arrival coordinates are captured before
   validation, outside caller-writable fields, and are never automatically stored.
   Runner holds the shared failed-wait budget outside replaceable workers.
   Compiled dependency levels batch counters through per-key machines. Store
   pipelines contain at most 4,000 operations and check the queued deadline before
   each. Owner calls reserve independently and run concurrently; pending owners
   wait for refunds within the same event deadline. Pipeline errors retain the
   whole-statement default and no-rollback policy; no uncertain write is replayed.
   `Guardian.Counters.Client` delegates routing and bounded dispatch to internal
   `Guardian.Counters.Transport`; its `remote_operation/3` endpoint sends native terms
   to one owner through the fully trusted Erlang
   distribution boundary (section 6), without another API or authorization layer.
   It captures connected members without readiness RPCs. Calls are bounded at
   50 ms, within a 100 ms event phase and a shared 250 ms failed-wait batch budget.
   An internal application-env test seam replaces the first two, including the
   remote endpoint's bound; nothing outside tests sets it, and values other than
   positive integers keep the defaults (`docs/changes/counter-test-budgets.md`).
   Killed callers retain reservations conservatively. A guard kills its linked
   RPC worker even under distribution flow control, and caller cleanup revokes
   aliases and flushes replies. Remote endpoints translate remaining duration
   onto their own clocks; already dispatched mutations can still complete late.
   `Guardian.Counters.Budget` owns reservations/deadlines and a separate member-keyed
   ETS cooldown that suppresses unavailable owners for a second,
   and timed-out owners only with at least 25 ms allowance; definite failures and
   budget skips never mark owners. No group keys or values are retained there.
   An unreachable owner's RPC failures become fixed error atoms; a raise on the owner
   crashes the rule worker.
   Store and Budget have a disposable supervisor whose linked lifecycle owner
   traps its exits and retries with backoff; counter crash loops cannot exhaust
   Guardian.Application's restart intensity. The owner's down/recovery messages use only fixed
   reason categories, never arbitrary exit/startup terms; its formatted status is not
   redacted. Process presence is sampled in
   `system_stats.counters_available`; `/health` remains Storage-only.
   Membership disagreement/loss, restarts, eviction and uncertain writes can lose
   or split counts; these counters are advisory, never durable enforcement limits.
   BY values and the states of arbitrary, min/max and the `_by` and `_n` forms
   can retain sensitive source values in owner memory
   and cross trusted distribution even after UNSET removes those fields from event
   storage. Old definition state remains until expiry/eviction, not erased by edits.

### 5.2 Gaps

Counter-specific limits:

- The positive MiB budget has no upper cap. Size it below available RAM with
  headroom for temporary overshoot, housekeeping's row copies and the rest of the
  VM; a VM crash dump can include counter ETS too (7.2).
- Untrusted high-cardinality BY inputs can fill the shared memory budget and evict
  other groups, or trigger stalls/cooldowns. A SET decision based on a default count
  can then fail open; it is an advisory signal, not a durable security limit.
- Top-N counters have no cap on n. A huge n makes each event's reads and CAS writes
  proportional to n, and Store's payload check measures external size, which is
  smaller than heap size, so a state Store accepts can still exceed the rule
  worker's heap limit and fail the event rather than fail open. An n taken from an
  event field lets one event with a different n fail its whole request with a 500.
  Use a literal n.
- UNSET is not counter-memory erasure. Avoid secret group keys and inputs to
  value-keeping aggregates (arbitrary, min/max, the `_by` and `_n` forms);
  they may remain for bucket_end+window (up to about 487 days at the maximum window)
  or appear in later computed fields. Distribution is fully trusted and unencrypted.
- WHERE false/null preserves caller-supplied outputs. Apply a counter unconditionally
  or explicitly set the skipped output before trusting it as a decision.
- Healthy responses refund the batch failure allowance; slow successful calls can
  accumulate up to the per-event phase across a large batch. The 250 ms allowance
  is not an end-to-end request deadline.

1. Regular expressions run in the VM, bounded but not cheap. `RLIKE` and `replace`
   run caller patterns on Erlang's `:re` (PCRE2, part of OTP), not in a NIF of
   Guardian's or a dependency's. That removes the confirmed crash path: the
   Hyperscan NIF used before aborted the node from `replace` whenever a pattern's
   reported matches grew or overlapped (`[0-9]+` on "123"). PCRE accepts
   backreferences and lookaround, which make heavy backtracking easy to write, so:
   - CPU: every run carries `match_limit` 1,000,000, hitting which gives null for
     that value. The limit counts per start position, so a value can still cost
     seconds (`a*[^a]` on 40 KB of `a` took 2.7 s without tripping it); the 30-second
     query time limit is the real bound. `:re` yields to the scheduler, so a long
     match does not block one.
   - Native memory: PCRE2 keeps backtracking frames in malloc'd memory that the
     per-process heap limit does not see, and a frame grows with the pattern's
     capturing groups. Patterns may have at most 32 capturing groups (a parse error
     otherwise) and every run carries `match_limit_recursion` 10,000, a depth limit
     under PCRE2, which together keep a run to a few MB. Without them, a pattern with
     hundreds of empty groups took over 1 GB on one value, enough to kill a 1 GB
     machine.
   - Match lists: `:re` returns every match offset of a value at once, about two per
     character at worst, which for millions of empty matches took hundreds of MB.
     Values up to 16 KiB are replaced in the calling process (at most about 33,000
     matches); a larger value is replaced in a helper process whose heap is capped at
     the query heap limit (256 MiB), so the list stays bounded. A value that needs
     more (about 600,000 matches) gives null. The cap is a heap budget
     checked at garbage collection, so it can overshoot somewhat, and it counts
     neither PCRE's native frames (bounded above) nor the result binary (bounded by
     the 64 KiB string cap). The helper's heap is on top of its caller's, so a worker's
     peak can roughly double during a replace, and many workers can each have a
     256 MiB helper at once.
2. Per-query resource bounds are partial. A query may return at most 100,000 rows and
   about 64 MiB, counted where rows collect on the machine running the query (the
   result, the input of an in-memory ORDER BY, the merge of ORDER BY ... LIMIT);
   ORDER BY with a LIMIT above the cap is refused; strings that functions build are cut
   to 64 KiB per value, though a whole column of them (to_string of a big non-string
   column, say) is rows times that in binaries the heap limit doesn't count; regular
   expressions have a backtracking limit, past which a value gives null (item 1). A query is stopped on every machine after 30 seconds
   (`query_time_limit_ms`), which bounds how long it holds memory and CPU but not how
   much memory it takes first. Exceeding a result or time bound fails the query with an
   error. These cover the common accidental cases (a SELECT without LIMIT over a big
   table). Functions return null or a cut string rather than fail or build an
   unbounded value (`factorial(100000000)` is null, `lpad('x', 2000000000)` is 64 KiB;
   `docs/changes/total-functions.md`).

   A heap guard covers part of the rest. A fixed 256 MiB Erlang `max_heap_size` is set
   on the query process and on every `Guardian.Query.DistributedStream` worker,
   including the initial worker that reads the first stage's input, but not on the
   routers. A process whose heap grows past the limit is killed, and the query fails
   with "a query process was killed; it may have exceeded its 256 MiB heap limit;
   narrow the query with WHERE, LIMIT or fewer groups".
   The message hedges because a `:killed` exit cannot prove which limit was hit. The
   VM writes no kill report: an over-limit query is the caller's outcome, not a fault
   to log.

   Its limits are real. It bounds each process, not the query: GROUP BY state lives
   in ETS tables, column data in NIF native memory, and shared binaries (mapped
   segment files among them) are not counted, so none of these is limited. The check
   happens at garbage collection, so a process can overshoot before it is killed. A
   query runs many processes, each of which can reach the limit, and nothing limits
   concurrent queries. So a deliberate or exotic query (a GROUP BY over millions of
   distinct keys, large intermediate columns, many concurrent heavy queries) can
   still exhaust a machine's memory, and because queries fan out to every connected
   node, all of them at once. An out-of-memory kill skips the graceful shutdown
   persist, so every affected machine loses its unpersisted events (section 1, asset
   5).
3. MCP calls in one session are serialized. Anubis 2.x runs each session in its own
   process and each request in its own task, one request at a time per session, so a
   slow call holds up only later requests in its session; other sessions, and new ones,
   are unaffected. Anubis's 30-second transport timeout abandons the caller's wait
   without stopping the request, and the query, which started a little later, stops at
   its own 30-second time limit. Resolving the query comes first and is not covered:
   for each distinct table a `SELECT *` reads from, `Guardian.Query.Resolver` asks every
   machine for that table's schema (`Guardian.Cluster.Metadata`, 60-second timeout), before
   the handler rejects input with several statements. Other SELECTs make no lookup.
   (`DESC`, `SHOW TABLES` and the `schema` table read the `schema` table, whose lookup
   runs inside the query and its limit.) Each lookup first asks every peer whether its
   Storage is ready, leaving out one that doesn't answer within 5 seconds; a ready
   machine whose Storage schema or in-memory segment doesn't answer fails the lookup
   after 5 seconds. So one MCP query holds its session for up to 30 seconds plus, per
   table a `SELECT *` names, up to 5 seconds when a machine doesn't answer at all, or
   up to 60 seconds when a machine reports ready and then stops answering; a slow
   `send_events` holds it until it finishes unless the client cancels it (the write
   itself still finishes, below). A key holder can open many sessions, so
   per-session isolation does not bound how many queries one caller runs at once; the
   per-query limits (2 above) are the bound. A client can stop its own query by
   cancelling the request or deleting its session (`Guardian.Query` kills a query whose
   caller dies); `send_events` runs in a `Guardian.Detached` worker and always
   completes. Exits from a running query do not reach the request: `Guardian.Query.run`
   runs each query in its own process and turns every failure inside it, such as a
   query worker or machine failing, into a `Guardian.Query.Error`, which the tool
   returns as a tool error.
4. Error messages reach the caller. The MCP `query` tool returns the message of a parse
   or query error, which can include internal detail such as peer node names
   (`guardian@<address>`). Acceptable for a single trusted principal. The same text,
   cut to 1 KiB, is stored in `queries.error`. An unexpected raise reaches the caller
   only as JSON-RPC -32603; its message stays in `queries.error` and the log.
5. Corrupt segment files abort the VM. The column NIF uses C asserts while unpacking,
   so a corrupt `.seg` file crashes the whole VM. A truncated, empty, or structurally
   malformed file is skipped instead, and its load failure is logged by kind only,
   without the file's bytes. Only an operator (or a disk fault) can put a file in the
   data directory, and the directory is rescanned about every 60 seconds, so a bad
   file restored from elsewhere takes effect without a restart. Not reachable from the
   API.
6. Ingestion shapes can be expensive: a list of objects with many distinct keys is
   slow to flatten. Bounded by the 8 MB body limit per request.
7. A segment that never stores (5.1.6) still holds its memory, and it is lost at
   shutdown like any unpersisted segment.
8. Rules (5.1.7): a rule set can cost up to a second of CPU per event, and a whole
   batch runs its events in turn, so a key holder can slow ingestion of a table. The
   write lock is a lease in the store, not a fence: a write that outlasts the
   two-minute lease, or a request the store applies after the writer abandoned it, can leave a stored set validation would have
   refused. Each node then fails that table's events from its next load until it is
   fixed, and the error quotes up to 40 characters of the rule to whoever sent them,
   the ingest key included. Anyone who can write to the rule store directly (the
   bucket's credentials, or the rule folder) controls ingest-time rules without an API key;
   those writes take effect at the next load and go through validation there. The S3
   endpoint is trusted too: its list responses are parsed by `req_s3` (`:xmerl` SAX, entities off, no
   atoms made), with no bound on pages, so a hostile endpoint could keep a read going and grow its memory.

## 6. B4: Machine to machine (clustering)

Guarantee: only nodes that hold the cookie and can reach the nodes' distribution ports
can join the cluster and run code on its nodes. The intended topology is that those
are exactly the Guardian nodes of one deployment; the code does not enforce that by
itself.

### 6.1 Mechanism

`rel/env.sh.eex` names the node in one of three modes (system architecture section 7):

1. Fly (`FLY_PRIVATE_IP` set): `guardian@<private IPv6>` over IPv6 TCP, with
   `DNS_CLUSTER_QUERY` defaulting to `<app>.internal`.
2. Elsewhere, `GUARDIAN_NODE_HOST=<address>`: `guardian@<address>`, over IPv6 TCP when
   the address contains `:`. With `DNS_CLUSTER_QUERY` set, the node discovers peers
   through it.
3. Neither set: a single node, `guardian@localhost`, with epmd and distribution bound
   to loopback.

Modes 1 and 2 refuse to start without `RELEASE_COOKIE`. With a discovery name,
DNSCluster polls it every 5 seconds (AAAA records for an IPv6 node, A for IPv4) and
connects to `guardian@<each address>`. Fan-out uses `:rpc.multicall` and `:erpc`,
which run arbitrary functions on the peer.

Invariants and argument:

1. Possession of the cookie is the authentication. Erlang distribution authenticates
   with a challenge-response digest of the cookie, so the cookie itself is not sent on
   the wire. The cluster guide generates it from 48 random bytes, the Fly guide from 32. Any node that knows it has
   full code execution on every node, as Guardian's OS user (root in the Docker image);
   there is no finer authority.
2. Distribution must not be reachable from outside the deployment. Who can reach epmd
   (4369) and the distribution port is the network half of admission; how that holds
   depends on the mode (6.2 to 6.4).
3. Discovery is not admission. DNSCluster only dials the addresses the discovery name
   lists. But any node with the cookie and network access can connect inbound, and
   `Guardian.Cluster` then treats it as a member (`connected_nodes/0` is this node plus every
   peer in `Node.list()` that answers `Guardian.Storage.ready?/0` with `true`, with no name or
   deployment allowlist). Counter routing instead uses this node plus `Node.list()`
   without Storage readiness checks (5.1.9), so a visible non-Guardian peer can own
   keys that then fail open. Membership is therefore exactly invariants 1 and 2.
4. A misnamed node fails at boot rather than silently never joining: with
   `DNS_CLUSTER_QUERY` set, `Guardian.Cluster.discovery_child_spec/2` refuses a node whose host
   is not an IP literal, is loopback, or is not written exactly as `:inet.ntoa/1`
   writes it (`2001:db8::1`, not an expanded form). This is a correctness check, not
   an admission control.
5. Guardian's own processes never carry the cookie on their command lines, because
   process lists get printed (`fly deploy` prints the table of listening processes when
   it warns about the expected address) and are visible to anything on the machine that
   lists processes. A release step in `mix.exs` removes the `--cookie` arguments from the
   generated `bin/guardian` and fails the build if that script ever passes the cookie
   another way. `rel/env.sh.eex` instead writes the cookie to an owner-only
   `.erlang.cookie` and points the VM's `HOME` at its directory, where OTP reads it. The
   server's file is under `RELEASE_TMP`; `remote`, `rpc`, `stop`, `restart` and `pid`
   write their own in a directory the user running them owns, their home or else
   `RELEASE_TMP`, and refuse to run with neither. So a client running as another user or
   with another cookie can't change what the server reads again on `System.restart`, and
   root never writes where a service account could swap the path for a symlink. A
   directory is refused if it's a symlink or someone else's, but that check can't be
   race-free in a directory others can write to, or under one, so `RELEASE_TMP` and the
   directories above it must not be writable by anyone but its owner when root runs a
   client there.
   The files stay on disk after the command exits.

### 6.2 On Fly

1. Distribution is not public. epmd and the distribution port are not among the services
   in the `fly.toml` that `fly launch` writes in the Fly guide, so they are reachable only over Fly's private 6PN network (B1).
2. Who is on that network: every machine in the Fly organization and its WireGuard
   peers. That is a property of the organization, not an invariant the code enforces:
   any app later added to the organization joins the same network.
3. Discovery lists only this app: Fly's DNS answers `<app>.internal` with this app's
   machines, and a machine in another app cannot appear there. A machine in this app
   running the image also joins; creating one requires deploy rights, which
   only operators have.
4. An operator-set `GUARDIAN_NODE_HOST` or `DNS_CLUSTER_QUERY` wins over the Fly
   defaults, so the arguments in 6.3 then apply.

### 6.3 Self-hosted clusters and distribution

A cluster on other machines (mode 2) has none of Fly's network isolation, so the
operator supplies it:

1. The cookie grants code execution on every node. Generate it at random, keep it as
   a secret like the API keys, and give every node the same one.
2. epmd (4369) and the distribution port must stay on a private network, reachable
   only by the other nodes. The distribution port is random by default;
   `GUARDIAN_DIST_PORT` pins it (for the server's `start` and `daemon` commands, not
   for `remote` or `rpc` clients) so a firewall can name it.
3. Distribution traffic is unencrypted (Guardian does not configure TLS
   distribution). Event rows, query results, and the closures nodes send each other
   cross the network in clear, and nothing protects a connection's integrity after
   the handshake. The private network must be trusted for both.
4. A shared cookie plus a discovery name merges deployments. Two environments (say,
   staging and production) that share a cookie and can reach each other become one
   cluster when either's `DNS_CLUSTER_QUERY` resolves to the other's nodes, or when
   one simply connects: every query and schema lookup then includes the other's
   events, and each can run code on the other. Use a distinct cookie per environment.
5. A standalone long-named node (`GUARDIAN_NODE_HOST` without `DNS_CLUSTER_QUERY`)
   discovers nothing, but it listens for distribution on all interfaces like any
   cluster member, so items 1 to 3 apply to it as well, and a node holding its cookie
   can still connect and join.

### 6.4 A single node

With neither `GUARDIAN_NODE_HOST` nor `FLY_PRIVATE_IP`, the node is short-named
`guardian@localhost`, `ERL_EPMD_ADDRESS=127.0.0.1` binds epmd to loopback, and
`-kernel inet_dist_use_interface {127,0,0,1}` binds the distribution listener to
loopback. Distribution is reachable only from the machine itself, which is what lets
`bin/guardian remote` and `rpc` work locally. No `RELEASE_COOKIE` is required; without
it the release uses the cookie generated into it at build time (`releases/COOKIE`),
so anyone who can run code on the machine and read the release can attach. That is
the same trust as a shell on the machine.

### 6.5 Gaps

1. Distribution traffic is unencrypted (6.3.3). On Fly it relies on Fly's private
   network, consistent with trusting Fly; elsewhere, on the operator's network.
2. There is no finer authority than the cookie, and no allowlist of member names
   (invariants 1 and 3).
3. The Docker image contains the build-time cookie (`releases/COOKIE`), readable by
   anyone with the image. It is unused whenever `RELEASE_COOKIE` is set, which modes 1
   and 2 require; a single node uses it, which is acceptable only because its
   distribution is bound to loopback (6.4).

## 7. B5 and B6: Operators, secrets, and data at rest

### 7.1 Operator access

Operators are fully trusted, and the design does not try to constrain them. On Fly:

1. `fly ssh console` gives a root shell on a machine (the image runs as root; the
   Dockerfile explains why). From there an operator can read every secret in the
   environment and every file on the volume.
2. The remote console (`fly ssh console --pty -C "/app/bin/guardian remote"`) attaches
   an Erlang shell to the running node using the cookie from the machine's
   environment. It bypasses the API keys by design (spec section 4.4) and can call any
   function, including `Guardian.Query.execute/1` and Storage internals that delete tables or
   segments.
3. The Fly guide's first `fly secrets set` takes the keys on its command line, so they
   pass through the operator's shell history and, briefly, the local process list
   (the cookie, generated inline, only the process list).
   `fly secrets set` also rotates a key or the cookie (each key independently); the
   machine restarts with the new value. Old keys stop working immediately after the
   restart.
4. `fly logs` shows stdout, including whatever section 8 says reaches it.

The boundary that protects all of this is Fly organization membership and Fly's
authentication. Elsewhere the same powers come from a shell on the host (or
`docker exec` into the container), the process environment, and the data directory,
and the boundary is whatever protects those. Guardian adds nothing on top.

### 7.2 Secrets inventory

| Secret | Where it lives | Who can read it | Rotation |
| --- | --- | --- | --- |
| `GUARDIAN_ADMIN_API_KEY` | process environment (on Fly, a Fly secret); app env `:guardian, :admin_api_key` | operators; the operator's agents and scripts | set the new value and restart (`fly secrets set` restarts); independent of the other keys |
| `GUARDIAN_INGEST_API_KEY` (optional) | process environment (on Fly, a Fly secret); app env `:guardian, :ingest_api_key` | operators; producers | set the new value and restart; independent of the other keys |
| `RELEASE_COOKIE` | process environment (on Fly, a Fly secret); node memory; owner-only `.erlang.cookie` files for the server and for whoever runs a client command, which stay on disk (6.1.5); never a command line | operators; peers | set the new value and restart; all nodes must share it |
| `TUNNEL_TOKEN` (optional) | process environment (on Fly, a Fly secret, also visible in `fly ssh` sessions); `bin/fly-start` unsets it before starting Guardian, so Guardian's process doesn't hold it; the script's shell and connector loop keep it, as cloudflared does | operators; whoever administers the operator's Cloudflare account | rotate the tunnel's token on Cloudflare, then set the new value and restart |
| `GUARDIAN_RULES_S3_ACCESS_KEY_ID`, `GUARDIAN_RULES_S3_SECRET_ACCESS_KEY` (optional) | process environment (on Fly, Fly secrets); read once by `Guardian.Rules.Config`, which looks up only the named `GUARDIAN_RULES_*` variables (never the whole environment, so no other secret is a function argument through this configuration path), into the `Guardian.ObjectStore.S3` config held by Guardian.Rules.Server and `:persistent_term`, never application config. It is plain config: its formatted status or a crash report can show it, so a Rules.Server crash report in the logs is a reason to rotate the key. Store errors name only a status or failure | operators; whoever administers the bucket's account | create a new bucket-scoped token, set both values and restart, then revoke the old token |
| Build-time cookie | `releases/COOKIE` in the release and image, copied to the same owner-only files as `RELEASE_COOKIE` | anyone with the image or release | per build; used only by a single node (6.4) |

Secrets also end up in any Erlang crash dump the VM writes (`erl_crash.dump` in the
working directory; on Fly, the machine's disposable root filesystem).

### 7.3 Data at rest

1. Segments live under `GUARDIAN_DATA_DIR/segments`. On Fly that is the machine's
   volume at `/data`, which Fly reports as encrypted, and production refuses to start
   on Fly if `/data` is not a mounted volume, so events cannot silently land on the
   disposable root filesystem (`config/runtime.exs`). Elsewhere, encryption at rest is
   whatever the operator's disk provides.
2. Retention deletes persisted segments about 15 days after creation, globally. There
   is no other deletion path through the product.
3. Backups: on Fly, the Fly guide creates each volume with daily snapshots kept 14
   days (`fly volumes create --snapshot-retention 14`). Snapshots hold everything the
   volume held, so deleted data, including `queries` and `query_parse_errors` query
   text, survives
   up to about 29 days after it was written. Snapshots are reachable only by
   operators. Elsewhere, backups are whatever the operator arranges. There is no
   replication.
4. `queries` and `query_parse_errors` store caller query text by design (spec
   section 3). It is the same principal's data, readable by the same principal; the
   spec tells callers not to put secrets in query text. `queries.error` also keeps the
   message of a failed query (up to 1 KiB), which can quote stored values or a remote
   failure (5.2.4).

## 8. B7: Logs and built-in tables

Guarantee wanted: event payloads, query text, and secrets stay inside Guardian's own
retention and access model.

Where data goes:

1. `web_requests` and `web_responses` record authenticated JSON API requests only,
   with the fields listed in spec section 8, among them the path without query
   string, method, host, remote IP, `x-forwarded-for`, referer, user agent,
   `auth_key` (`ingest` or `admin`; older rows may say `legacy`),
   and for responses status, size, and timing. There are no body or key fields; the
   one way a key can land there is the verbatim `referer` header (4.1.3). Any key
   holder, the ingest key included, can also append rows to these tables (4.6).
2. `query_parse_errors` records failing query text with bounds (5.1.5).
3. `queries` records every MCP query's text, timing, row count and outcome,
   with the same text bounds, plus remote IP and MCP client info; no request header,
   so neither the key nor any other header value.
4. `system_stats` records VM metrics and counter process availability; no request data.
5. stdout (on Fly, Fly's log stream) receives more caller data than the tables do:
   - `Guardian.Web.JsonApi` uses `Plug.ErrorHandler`: a failure gets its response
     (a bare 500, or a fixed 400, 413 or 415 for a body or query string Plug refuses)
     and is reraised, so Bandit prints a 5xx with the full exception and stack, which
     can hold query text or event values, and closes the connection. It prints no 4xx.
     The JSON router drops the `x-api-key` header once it is checked, so no plug or
     handler after that check has it. Bandit also attaches its own
     connection, built before any plug and so with the header, as Logger metadata on
     that line. Guardian's formatter prints no metadata (no `metadata:` in `config/`);
     a formatter set to print `conn` or `crash_reason` would expose the key, so don't
     configure one. Bandit transport/protocol exceptions pass through unchanged to
     its own status, cleanup and logging policy.
   - A `web_requests`, `web_responses`, `system_stats`, `query_parse_errors` or
     `queries` write
     that fails is logged with the table and the failure's kind only (an exception
     module or exit kind, from `Guardian.Engine.try_log_event/2`), never the event or the
     exception's message, and the request, if any, still answers normally.
     `query_parse_errors` and `queries` log the same way when building or handing off
     a row fails.
   - OTP crash reports for crashed processes (segments, an Anubis session) include the
     last message and state, which can hold event data. A segment file that fails to
     load is not a crash: its process stops with a `:shutdown` reason naming only the
     failure's kind, so no crash report carries the file's bytes.
   - Guardian.Rules.Server's state is not redacted: its formatted status and a crash
     report's state and last message can show the S3 secret and rule text (rules can
     hold secrets, such as a value a SET compares against). Compiled modules hold their execution
     levels (typed steps, with canonical source and expression constants) as escaped
     literal data, whose lifetime is bounded by the fixed module pool and normal code
     reclamation. The
     synchronous Rules.Publisher helper runs inside Server's callbacks; its state
     holds only module names and retirement statuses, never sources, plans or
     diagnostics, and a compile failure's log line names the table and failure kind,
     no rule text. Raw module/process inspection remains privileged full-memory
     access. A callback that raises crashes as is, so a crash report can show rule
     text. `Guardian.Rules.Server.write/3` turns a
     timed-out or missing server into an error without logging the exit reason, which
     carries the message. Proc_lib and supervisor reports (which include the message
     queue) are SASL reports, which Logger drops in this configuration.
   - Guardian.Counters.Store's, Budget's, Restarter's and IngestIdempotency's
     formatted status is not redacted, and a Store callback failure crashes as is, so
     a crash report can show counter keys and values or idempotency keys. Ordinary
     operations do not log their arguments or returned values.
     The counter lifecycle owner logs subtree exits and failed recovery attempts
     at error with fixed reason categories and a retry delay, and recovery at info.
     Clean application shutdown stops the subtree without logging a failure.
     This configuration drops SASL reports.
   - Invalid rules are not logged: a validation message can quote up to 40
     characters of a rule. A table's first message reaches whoever sends its events,
     the ingest key included (5.2, item 8), and rule writes return the set's remaining
     messages.
   - A query process killed by the heap guard produces no kill report (5.2.2).

Caller-supplied fields are not identities. `remote_ip` is the address of whatever
connected to Guardian (on Fly, Fly's proxy; for tunnel traffic, `127.0.0.1`), and
`x-forwarded-for` and `user_agent` are whatever the client sent (Fly appends to
`x-forwarded-for`, but earlier entries are client-controlled). Treat them as hints.

Log level: production logs at `:info`, set in `config/config.exs` because that file is
compiled into the release, and a test reads the production config and requires
`:info`. The level matters because Anubis logs a line for every MCP message and
session event at debug (methods, request IDs, session IDs, client info; Anubis 0.16
also logged each whole message there, with its query SQL or events). Anubis decides
whether to log by comparing its message level with `:logger, :level`
(`Anubis.Logging.should_log?/1`), so at `:info` those lines are dropped; its warnings
and errors still appear and mostly carry error structs, not message bodies, with three
exceptions read from Anubis's source. A request-validation error can quote the
offending argument value, and a client-sent JSON-RPC response that answers no server
request is logged whole (`unexpected_response`); both need the admin key. And when a
request outlasts Anubis's 30-second call timeout, or its session exits mid-call, the
transport logs the call's exit reason at `:error` (`session_call_failed`), which holds
the message (query SQL, events, rule source; `inspect/1` cuts very long values short)
and every request header but the key. Logs are
not scrubbed (CONTRIBUTING.md, "Logging"), so that line is kept as Anubis writes it,
even when the call later succeeds. The MCP router drops every `x-api-key` header once
the key passes, so the key reaches neither that line nor any Anubis session state.
A session's OTP crash report can show a message, and `request_task_crashed` logs a
crashed request task's reason at `:error`, which may hold its arguments if it crashes
inside a call. Production must stay at `:info` or above.

MCP bodies Anubis cannot decode: Anubis 0.16's transport plug logged the whole body of
any MCP message it could not decode; 2.x logs only its size. `Guardian.Web.MCP.Router`
decodes and validates the body itself anyway (4.3) and hands Anubis the decoded map;
it answers a rejected body with a JSON-RPC error and logs nothing.

The remaining stdout leaks above are accepted: they are bounded by error frequency
and reach only operators. Bandit's and Plug's telemetry emit raw reasons, stacks and
connection data; privileged in-process telemetry handlers can read those. Guardian attaches no
telemetry handlers. Installing one has the same trust as running code inside the VM.

Failed authentication is not logged anywhere (4.2.4).

## 9. Known gaps

Open gaps named above, by boundary:

1. B1: on Fly, a client configured with `http://` sends its first request, key
   included, in clear before the redirect, and no HSTS header is sent (3).
2. B1: Bandit listens on every IPv4 interface, so on hosts that do not firewall the
   port, clients can bypass the edge's TLS and any edge concurrency limit (3).
3. B1b: anyone with the tunnel token can run a connector and receive some requests;
   the connector has no destination allowlist, so administrative access to the
   operator's Cloudflare account reaches the deployment's private network (3).
4. B2: the keys' lengths are observable through timing (4.2.1).
5. B2: the 32-byte minimum is a length policy, not an entropy check (4.2.2).
6. B2: failed authentication is not logged, rate-limited, or alerted on (4.2.4).
7. B3: no bound on a query's total memory. The heap guard limits each query process's
   own heap but not ETS, native column memory, or shared binaries, and can
   overshoot; a deliberate or exotic query can still exhaust memory on every node and
   lose unpersisted events (5.2.2).
8. B3: one slow MCP call delays later requests in its session (a query for up to its
   30 s limit plus, for a `SELECT *`, its schema lookup; an ingest until done unless
   cancelled) (5.2.3).
9. B3: MCP error messages can carry internal detail such as node names (5.2.4).
10. B3, B6: a corrupt segment file aborts the VM (5.2.5).
11. B3: some event shapes are slow to flatten (5.2.6).
12. B3: a segment that never stores holds its memory and is lost at shutdown (5.2.7).
13. B4: distribution traffic is unencrypted; the cookie is the only authority, with no
    member allowlist (6.5).
14. B4: the image carries a build-time cookie, used by a single node (6.5.3).
15. B5: secrets end up in any Erlang crash dump (7.2), the rule store's S3 secret
    included.
16. B7: caller data can reach stdout in failures outside the JSON application
    boundary and OTP crash reports, and the `referer` header is stored verbatim
    (4.1.3, 8).
17. B3: rules can slow a table's ingestion by up to a second per event; the rule
    write lock is a lease, not a fence; direct writers to the rule store bypass the
    API keys (5.2.8).
18. B2: the ingest key can read counter values (and other rule outputs) for keys it
    chooses through `return_keys` (4.6).
19. B2: the ingest key can append forged rows to any table, built-in ones included,
    so `web_requests.auth_key` and other built-in rows are evidence, not proof (4.6).
20. B2: rolling back to a release without the ingest key refuses callers that use it
    (4.6).

## 10. How this was checked

Written from the code: the routers, `Guardian.Web.Auth`, `Guardian.Web.Logger`, `Guardian.Web.QueryParseErrors`,
`Guardian.Web.QueryLog`, `Guardian.Engine`, `lib/guardian/rules`, `Guardian.Cluster`, `Guardian.Query.Limits`, `config/runtime.exs`,
`rel/env.sh.eex`, `bin/fly-start`, `Dockerfile`, and the Fly guide in this repository,
and the pinned dependencies `cors_plug` 3.0.3, `anubis_mcp` 2.2.0, `req` 0.7.5 and `req_s3` 0.2.5. Query
regular expressions (`RLIKE`, `replace`) run on OTP's `:re` through `Guardian.Query.Regex`. Statements about Fly's platform
(volume encryption, private network membership, edge behavior) come from Fly's
tooling and documentation, not from Guardian's code. Where something was read from a
dependency's source rather than tested, the text says so.

When code on one of these boundaries changes, update the matching section here.

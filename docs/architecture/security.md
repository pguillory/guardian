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
2. Caller query text: by design kept for every query run over the JSON API or MCP,
   in `queries`, and for queries that fail to parse, in `query_parse_errors`, for the
   15-day retention period (and in any backup or volume
   snapshot for as long as that is kept, section 7). Fragments of JSON API queries
   also reach the server log through printed errors (section 8).
3. The API key (`GUARDIAN_API_KEY`): the only credential for the HTTP and MCP
   interfaces.
4. The Erlang cookie (`RELEASE_COOKIE`): grants full code execution on every node to
   any Erlang node that can reach the nodes' distribution ports.
5. Availability and integrity of recent events: events not yet persisted live only in
   memory. A table's in-memory segment is handed off for persistence after one hour by
   default (spec section 9), and queue or disk delays can stretch the time to disk
   beyond that, so anything that kills the VM without a graceful stop loses every event
   not yet on disk: by default up to the last hour of each table, longer when
   persistence is backed up.

Principals:

1. Key holder: anyone presenting the key. Guardian is single-tenant (spec section 3):
   every key holder is the same principal with full read and write access. In practice
   that is the operator's agents, scripts, and producers.
2. Operator: whoever holds the deployment. On Fly, that is every member of the Fly
   organization that owns the app; elsewhere, whoever administers the machines, their
   environment, and their disks. Operators hold everything: secrets, shell, data,
   logs.
3. Peer node: another Guardian node that holds the cookie and can reach this one
   (section 6).
4. Anonymous network client: anyone who can reach the HTTP port, on Fly anyone on the
   internet.

Out of scope: the hosting platform (on Fly, its edge, hypervisor, private network,
secret store, and snapshot storage are trusted; elsewhere, the operator's hosts and
network), the build toolchain and Hex dependencies (pinned in `mix.lock`; see the
[dependency pins](system.md#104-dependency-pins)), and producers' own handling of the key.

## 2. Boundaries at a glance

```text
 network client                         the operator's Cloudflare Workers
        |  B1: TLS at the deployment's         |  B1b: optional Cloudflare Tunnel,
        |      edge (on Fly, Fly's proxy),     |       opened outbound by cloudflared
        |      HTTP to the node                v       on the node
        v
 Bandit HTTP server (GUARDIAN_PORT, default 8080)  -- GET /health, CORS preflight
        |  B2: API key check (x-api-key header; api_key query parameter only if allowed)
        v
 key holder: JSON API handlers, MCP server
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

1. Routes: `Web.MainRouter` serves `GET /health`, forwards `/api/json` to
   `Web.JsonApi` and `/mcp` to `Web.MCP.Router`, and answers 404 to everything else.
2. On Fly, only the HTTP service is public. `fly.toml` declares one `[http_service]`
   (internal port 8080) and no other services, so Fly's edge forwards only HTTP and
   HTTPS on the app's public addresses. Erlang distribution ports and epmd are not
   published; they are reachable only on Fly's private network (section 6).
3. On Fly, TLS terminates at Fly's edge. `force_https = true` makes the edge redirect
   plain HTTP to HTTPS. From the edge to the machine, traffic is plain HTTP on Fly's
   internal network, which is out of scope here.
4. On Fly, concurrency is bounded at the edge: `hard_limit = 250` requests per machine
   (`[http_service.concurrency]`).
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
   connector itself limits nothing (gap 4). The same routes and the same API key (B2)
   apply. Fly's edge controls do not: no `force_https` redirect, no edge TLS, and the
   `hard_limit` concurrency bound doesn't count this traffic. Such requests reach
   Guardian from `127.0.0.1`, so `web_requests.remote_ip` shows that, not the Worker.
   The script starts the connector only once Guardian listens and stops it before
   Guardian on shutdown, and `GUARDIAN_TUNNEL=off` keeps it from starting at all; in
   every case the token is unset before Guardian starts.

Gaps:

1. On Fly, the redirect does not protect a client configured with `http://`: its first
   request, key included, crosses the internet in clear before the redirect. No HSTS
   header is sent. This is a client configuration risk; the product could reject
   instead of redirect, but does not.
2. Bandit listens on every IPv4 interface of the machine (`Web.init/1` passes no
   `:ip`, so Bandit's IPv4 default applies). On Fly, whose private network is
   IPv6-only, the port is probably not reachable there, bypassing the edge; this was
   not verified. Elsewhere, the port is reachable from any network that reaches the
   host unless the operator firewalls it. Either way the key is still required (B2),
   but that traffic skips the edge's TLS and concurrency limit.
3. Anyone holding the tunnel token can run their own connector for the same tunnel,
   and Cloudflare may then send them some of the Workers' requests, API key included.
   The token is therefore kept like `GUARDIAN_API_KEY`: a secret, never logged
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

## 4. B2: API key

Guarantee (spec section 3): no event data is read or written without the key. Besides
401s and 404s, the only responses the application serves without a key are
`GET /health` and CORS preflight answers, plus, only when query-parameter keys are
allowed, the failure of a query string Plug cannot decode (invalid UTF-8, nesting
deeper than 32, or over Plug's length limit). With query keys allowed, the key check
decodes the query string when the request has no `x-api-key` header, so such a
request gets 400 (or 414 over the length limit) instead of 401: the JSON API answers
with the fixed `info` "invalid query string" and `/mcp` with
`{"error": "invalid query string"}`, and neither prints anything. With query keys off
(the default), the query string is never decoded before the key check, and a request
without the header is 401. None of these reads or writes data.

### 4.1 Where the key lives

1. In the environment: on Fly, a Fly secret injected into the machine's environment
   at boot; elsewhere, however the operator sets the process environment.
   `config/runtime.exs` reads `GUARDIAN_API_KEY` with `System.fetch_env!` and refuses
   to start if it is missing, empty, or shorter than 32 bytes, then stores it in the
   application environment (`:guardian, :api_key`).
2. Tests use a fixed key in `config/config.exs`; it protects nothing.
3. Guardian does not record the key itself: the `x-api-key` header and the `api_key`
   query parameter are not in `web_requests` (which records `path`, the request path
   without the query string, selected headers, and `auth_method`, which says only
   whether the key came from the header or the query parameter), not in
   `query_parse_errors` (caller fields are remote IP, `x-forwarded-for`, user agent,
   and MCP client info), not in `queries` (remote IP and MCP client info only, no
   request header), and not in any log line of a well-formed request found in the
   code (section 8). One exception: `web_requests` stores the `referer` header
   verbatim, so a caller whose referring URL contains `?api_key=` gets the key
   recorded there.

### 4.2 How the key is checked

Both routers call `Web.Auth.check_conn/1`, the one place a key is found and checked.
It reads the first `x-api-key` header if present. Otherwise, only when
`GUARDIAN_ALLOW_QUERY_API_KEY=true`, it decodes the query string and reads the
`api_key` parameter. A valid key returns `{:ok, :header}` or `{:ok, :query}`, saying
where it was found. No key is `{:error, :missing}`; with query keys allowed, a query
string that cannot be decoded is `{:error, {:invalid_query, status}}` (400, or 414
over Plug's length limit). Each router sends its own body for these and for a wrong
key, pinned for each credential form by `test/web/auth_routes_test.exs` (an
undecodable query string is covered at `check_conn/1` in `test/web/auth_test.exs`,
MCP's answer to it in `auth_routes_test.exs`, and the JSON API's in
`test/web/json_api_test.exs`). `Web.Auth.authorize_api_key/1` requires
`byte_size(supplied) == byte_size(configured)` and
`Plug.Crypto.secure_compare(supplied, configured)`. A structured parameter, which
Plug decodes from `?api_key[]=x` to a list or from `?api_key[a]=x` to a map, is not a
key: it is rejected like a wrong one, with 401 and nothing printed.

Argument: `secure_compare` examines every byte of equal-length inputs regardless of
where they differ, so response timing does not reveal how much of a guess is correct.
The comparison is exact bytes: no trimming, case folding, or decoding beyond what
Plug does to headers and query strings.

Gaps:

1. Length is observable. The explicit size check (and `secure_compare`'s own) returns
   faster for a wrong length than for a wrong value. This reveals only the key's
   length, which matters little for a long random key.
2. The minimum is a length policy, not an entropy check. Startup refuses a key shorter
   than 32 bytes, but a long guessable key passes. The docs and the startup error
   say to generate one with `openssl rand -hex 32`; nothing checks that it was.
3. Query-parameter keys put the key in the URL. They are off by default; with
   `GUARDIAN_ALLOW_QUERY_API_KEY=true`, URLs carrying the key end up in client-side
   logs, shell history, proxy logs, and browser history more readily than headers.
   Guardian does not store request URLs (only the `referer` header, item 4.1.3). To
   show whether the setting is still needed, `web_requests.auth_method` records
   `query` for each JSON API request that used it, and, since MCP requests are not
   recorded in `web_requests`, `Web.MCP.Router` logs one info line naming the path
   (never the key) when an MCP request uses it, at most once a minute per node.
   Because of CORS (section 4.4), the query parameter is the only way a browser page
   can send the key, so a browser client needs the setting on.
4. Failed attempts leave no trace. A request with a wrong or missing key is rejected
   with 401 before `Web.Logger` runs (JSON API) or before Anubis sees it (MCP), and
   nothing is written to stdout. There is no rate limit, lockout, or alert, so
   guessing is invisible. With a long random key guessing is infeasible; with a weak
   key it would be both feasible and unseen.

### 4.3 The two authenticated surfaces

JSON API (`Web.JsonApi`), plug order:

1. `CORSPlug`: adds CORS headers; answers a preflight (`OPTIONS` with
   `Access-Control-Request-Method`) with 204 and halts.
2. `:auth`: the key check; 401 and halt on failure. It reads only headers and, when
   query keys are allowed, the query string. It records where the key was found for
   `Web.Logger`.
3. `Plug.Parsers` (JSON only, Plug's default 8 MB body limit): reads and decodes the
   body. Failures get 400, 413, or 415 with a fixed message and are not printed.
4. `:match`, `Web.Logger`, `:dispatch`.

MCP (`Web.MCP.Router`), plug order:

1. `:auth`: the key check, first.
2. `:reject_unknown_session` (404), `:reject_get` (405).
3. `:decode_body` (POST): reads up to 8 MB (413 above) and decodes it as one valid
   JSON-RPC message; anything else gets 400 with a JSON-RPC error and a log line with
   only size, reason, and a known method name (any other method is logged as `other`).
4. Forward to Anubis's Streamable HTTP plug with the decoded body, so Anubis neither
   reads nor decodes it.

Argument that no data moves without the key: every handler that touches Storage or the
query engine (`/send_events`, `/query`, and the MCP tool and resource handlers) sits
behind `:auth` in its router's pipeline, and a plug that halts stops the pipeline.
CORSPlug's preflight answer runs before `:auth` but calls no handler and reads no
body.
MCP sessions carry no authority of their own: every request, including one naming an
existing session ID, passes `:auth` again, so a leaked session ID is useless without
the key, and rotating the key takes effect on the next request.

The JSON API checks the key before reading the body, so an anonymous client cannot
make the server allocate memory and CPU to parse up to 8 MB of JSON per request. Tests
show a request without a valid key gets 401 with its body unread, including a 9 MB
body. Key holders can still send 8 MB bodies, which is the product's ingestion limit.

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

Side effect: a browser page cannot send `x-api-key` cross-origin, so browser clients
must put the key in the URL, which works only with query keys allowed (gap 4.2.3).

### 4.5 Unauthenticated responses

1. `GET /health` returns `200 ok`, reads no data, and is served only after Storage
   has loaded (the HTTP listener starts after Storage in the supervision tree). While
   Storage restarts it returns `503 storage unavailable`, which reveals only that.
2. Preflight 204s carry CORS headers only.
3. 401 bodies distinguish "api_key required" from "unauthorized", which reveals only
   whether a key was sent.
4. Unknown paths answer 404 without revealing whether they would exist with a key,
   except that `/api/json/*` and `/mcp` answer 401 without a key where other paths
   answer 404. The route list is public in the spec anyway.

## 5. B3: Key holder to query engine and storage

Guarantee: there is no confidentiality boundary here, because every key holder is the
same principal with full access (spec section 3). What this boundary must guarantee
is that a key holder cannot exceed the product's interface: no code execution, no file
access outside segment files, no reading process secrets, no writes beyond ingestion,
and no single request that takes the service down or destroys stored data.

### 5.1 What holds

1. Read-only SQL. The parser and planner implement SELECT, SHOW TABLES, DESC, and LET
   only; there is no INSERT, UPDATE, DELETE, or DDL (spec section 7). Writes happen
   only through `send_events`, which goes through `Engine`.
2. No path or atom injection from names. Table names must match
   `[a-z_][a-z0-9_]*` and avoid reserved words (`Engine.valid_table_name?/1`), checked
   before any write; segment filenames are built only from a validated table name and
   a generated segment ID, so a table name cannot escape `segments/`. Table names are
   at most 64 bytes, which keeps a segment's temporary filename
   (`{table}.{32-character id}.seg.{n}.tmp`) inside the filesystem's 255-byte name
   limit. Queries do not open segment files by table name: they look up tables already
   registered in memory. Nothing in `lib/` converts caller strings to atoms
   (`String.to_atom` and friends do not appear), so the atom table cannot be exhausted
   from input.
3. No dynamic code. Nothing in `lib/` evaluates code, runs shell commands, or decodes
   Erlang terms from input (`Code.eval`, `System.cmd`, `:os.cmd`, and
   `binary_to_term` do not appear).
4. Value validation. `Engine` drops values the column NIF cannot store (out-of-range
   integers, over-deep lists, oversized strings and lists, keys over 250 bytes) before
   they reach native code (spec section 5).
5. Query parse failures are recorded asynchronously and with fixed bounds (16 KiB SQL,
   1 KiB error, 256-byte caller fields, 60 rows per machine per hour, queue cap 100), so
   a flood of bad queries cannot grow that table or delay responses without limit
   (`Web.QueryParseErrors`). Every API query is recorded the same way in `queries`
   (`Web.QueryLog`): 16 KiB SQL, 1 KiB error, 256-byte caller fields, queue cap 1,000
   rows, and no rate cap, since each query writes one row whose cost is of the order
   of the query's own.
6. A segment the persister cannot store (for any reason, such as a full disk) is
   logged once, stays in memory and queryable, and is retried on every pass while
   other segments persist, so one bad segment does not stall persistence.

### 5.2 Gaps

1. Regular expressions run in the VM, bounded but not cheap. `RLIKE` and `replace`
   run caller patterns on Erlang's `:re` (PCRE2, part of OTP), not in a NIF of
   Guardian's or a dependency's. That removes the confirmed crash path: the
   Hyperscan NIF used before aborted the node from `replace` whenever a pattern's
   reported matches grew or overlapped (`[0-9]+` on "123"). PCRE accepts
   backreferences and lookaround, which make heavy backtracking easy to write, so:
   - CPU: every run carries `match_limit` 1,000,000, hitting which fails the query
     with an error. The limit counts per start position, so a value can still cost
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
     the query heap limit, or 256 MiB when that is off (`GUARDIAN_QUERY_MAX_HEAP_MB=0`),
     so the list stays bounded either way. A value that needs more (about 600,000
     matches at 256 MiB) fails the query with an error. The cap is a heap budget
     checked at garbage collection, so it can overshoot somewhat, and it counts
     neither PCRE's native frames (bounded above) nor the result binary (bounded by
     the 16 MiB string cap). The helper's heap is on top of its caller's, so a worker's
     peak can roughly double during a replace, and with the setting at 0 many workers
     can each have a 256 MiB helper at once. The per-value match bound scales with the
     setting.
2. Per-query resource bounds are partial. A query may return at most 100,000 rows and
   about 64 MiB, counted where rows collect on the machine running the query (the
   result, the input of an in-memory ORDER BY, the merge of ORDER BY ... LIMIT);
   ORDER BY with a LIMIT above the cap is refused; `lpad`, `rpad`, `concat`, `||`, and
   `replace` refuse strings over 16 MiB; `factorial` takes at most 20; regular expressions
   have a backtracking limit (5.2.1). A query is stopped on every machine after 30 seconds
   (`query_time_limit_ms`), which bounds how long it holds memory and CPU but not how
   much memory it takes first. Exceeding one fails the query with an error. These
   cover the common accidental cases (a SELECT without LIMIT over a big table,
   `lpad('x', 2000000000)`, `factorial(100000000)`).

   A heap guard covers part of the rest. `GUARDIAN_QUERY_MAX_HEAP_MB` (default 256,
   `0` turns it off) sets Erlang's `max_heap_size` on the query process and on every
   `Query.DistributedStream` worker, including the initial worker that reads the first
   stage's input, but not on the routers. Each node reads its own setting when a
   worker starts there. A process whose heap grows past the limit is killed, and the
   query fails with "a query process was killed; it may have exceeded its heap limit
   (GUARDIAN_QUERY_MAX_HEAP_MB); narrow the query with WHERE, LIMIT or fewer groups".
   The message hedges because a `:killed` exit cannot prove which limit was hit. The
   VM's kill report, written to the log, names the process and its heap sizes, not
   its heap contents.

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
   5). A deployment that sets the limit to `0` (the repository's `fly.toml`, which is
   the maintainer's own deployment, does) has only the caps above.
3. MCP calls are serialized. Anubis 0.16 runs tool calls inside its one server
   process (`Anubis.Server.Base.handle_call/3`), so a slow MCP query blocks the
   execution of every other MCP tool and protocol request on that machine
   (notifications are acknowledged without waiting but processed behind it; DELETE and
   the GET rejection never reach that process). The 30-second transport timeout
   abandons the caller's wait, and the query, which started a little later, stops at
   its own 30-second time limit. Resolving the query comes first and is not covered:
   for each distinct table a statement reads from, `Query.Resolver` asks every machine
   for that table's schema (`Cluster.Metadata`, 60-second timeout), before the handler
   rejects input with several statements. (`DESC` and `SHOW TABLES` read the `schema`
   table, whose lookup runs inside the query and its limit.) Each lookup first asks
   every peer whether its Storage is ready, leaving out one that doesn't answer within
   5 seconds. So one MCP query holds the process for up to 30 seconds plus up to 5
   seconds per table it names when a machine doesn't answer at all, or up to 60
   seconds per table when a machine reports ready but its schema lookup hangs; a slow
   `send_events` still holds it until it finishes.
   HTTP JSON queries run in their own request processes and stop at the same time
   limit. Exits from a running query do not reach that shared server process:
   `Query.run` runs each query in its own process and turns every failure inside it,
   such as a query worker or machine failing, into an exception the handler rescues.
4. Error messages reach the caller. The MCP `query` tool returns `Exception.message/1`
   of whatever was raised, which can include internal detail such as peer node names
   (`guardian@<address>`). Acceptable for a single trusted principal. The same text,
   cut to 1 KiB, is stored in `queries.error` for both interfaces, including HTTP
   queries whose response is a bare 500 (before, that message reached only stdout).
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
   the wire. The cluster and Fly guides generate it from 48 random bytes. Any node that knows it has
   full code execution on every node, as Guardian's OS user (root in the Docker image);
   there is no finer authority.
2. Distribution must not be reachable from outside the deployment. Who can reach epmd
   (4369) and the distribution port is the network half of admission; how that holds
   depends on the mode (6.2 to 6.4).
3. Discovery is not admission. DNSCluster only dials the addresses the discovery name
   lists. But any node with the cookie and network access can connect inbound, and
   `Cluster` then treats it as a member (`connected_nodes/0` is this node plus every
   peer in `Node.list()` that answers `Storage.ready?/0` with `true`, with no name or
   deployment allowlist). Membership is therefore exactly invariants 1 and 2.
4. A misnamed node fails at boot rather than silently never joining: with
   `DNS_CLUSTER_QUERY` set, `Cluster.discovery_child_spec/1` refuses a node whose host
   is not an IP literal, is loopback, or is not written exactly as `:inet.ntoa/1`
   writes it (`2001:db8::1`, not an expanded form). This is a correctness check, not
   an admission control.

### 6.2 On Fly

1. Distribution is not public. epmd and the distribution port are not in `fly.toml`'s
   services, so they are reachable only over Fly's private 6PN network (B1).
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
   a secret like the API key, and give every node the same one.
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
   environment. It bypasses the API key by design (spec section 4.4) and can call any
   function, including `Console.query/1` and Storage internals that delete tables or
   segments.
3. `fly secrets set` rotates the key or cookie; the machine restarts with the new
   value. Old keys stop working immediately after the restart.
4. `fly logs` shows stdout, including whatever section 8 says reaches it.

The boundary that protects all of this is Fly organization membership and Fly's
authentication. Elsewhere the same powers come from a shell on the host (or
`docker exec` into the container), the process environment, and the data directory,
and the boundary is whatever protects those. Guardian adds nothing on top.

### 7.2 Secrets inventory

| Secret | Where it lives | Who can read it | Rotation |
| --- | --- | --- | --- |
| `GUARDIAN_API_KEY` | process environment (on Fly, a Fly secret); app env `:guardian, :api_key` | operators; callers who hold it | set the new value and restart (`fly secrets set` restarts) |
| `RELEASE_COOKIE` | process environment (on Fly, a Fly secret); node memory | operators; peers | set the new value and restart; all nodes must share it |
| `TUNNEL_TOKEN` (optional) | process environment (on Fly, a Fly secret, also visible in `fly ssh` sessions); `bin/fly-start` unsets it before starting Guardian, so Guardian's process doesn't hold it; the script's shell and connector loop keep it, as cloudflared does | operators; whoever administers the operator's Cloudflare account | rotate the tunnel's token on Cloudflare, then set the new value and restart |
| Build-time cookie | `releases/COOKIE` in the release and image | anyone with the image or release | per build; used only by a single node (6.4) |

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
3. Backups: on Fly, the repository's `fly.toml` has Fly snapshot the volume daily and
   keep snapshots 14 days (`snapshot_retention = 14`). Snapshots hold everything the
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
   `auth_method` (`header` or `query`), and for responses status, size, and timing.
   There are no body or key fields; the one way the key can land there is the
   verbatim `referer` header (4.1.3).
2. `query_parse_errors` records failing query text with bounds (5.1.5).
3. `queries` records every JSON and MCP query's text, timing, row count and outcome,
   with the same text bounds, plus remote IP and MCP client info; no request header,
   so neither the key nor any other header value.
4. `system_stats` records VM metrics; no request data.
5. stdout (on Fly, Fly's log stream) receives more caller data than the tables do:
   - `Web.JsonApi.handle_errors/2` prints every exception in full. Parse errors carry
     SQL fragments. Body failures (malformed JSON 400, too large 413, wrong content type
     415), a `/query` body without a string `query` (400), and an undecodable query
     string (400) are answered without printing.
   - `Engine` logs `Exception.format/3` of any ingestion crash, and a stack trace can
     carry the event values passed to the failing function.
   - A `web_requests`, `web_responses`, `system_stats`, `query_parse_errors` or
     `queries` write
     that fails is logged with the table and the failure's kind only (an exception
     module or exit kind, from `Engine.try_log_event/2`), never the event or the
     exception's message, and the request, if any, still answers normally.
     `query_parse_errors` and `queries` log the same way when building or handing off
     a row fails.
   - OTP crash reports for crashed processes (segments, the Anubis server) include the
     last message and state, which can hold event data. A segment file that fails to
     load is not a crash: its process stops with a `:shutdown` reason naming only the
     failure's kind, so no crash report carries the file's bytes.
   - A query process killed by the heap guard produces the VM's kill report, which
     names the process and its heap sizes, not its contents (5.2.2).
   - With query keys allowed, an MCP request that uses one logs one info line naming
     the path, never the key, at most once a minute per node (4.2.3).

Caller-supplied fields are not identities. `remote_ip` is the address of whatever
connected to Guardian (on Fly, Fly's proxy; for tunnel traffic, `127.0.0.1`), and
`x-forwarded-for` and `user_agent` are whatever the client sent (Fly appends to
`x-forwarded-for`, but earlier entries are client-controlled). Treat them as hints.

Log level: production logs at `:info`, set in `config/config.exs` because that file is
compiled into the release, and a test reads the production config and requires
`:info`. The level matters because Anubis 0.16 logs every parsed MCP message at debug
(`MCP transport event: parsed_messages` followed by `inspect` of the message and the
session ID), so at debug each MCP `tools/call` would put up to about 4 KiB of query
SQL, or roughly the first 50 events of a `send_events` call, into the log stream,
outside Guardian's 15-day retention. Anubis decides whether to log by comparing its
message level with `:logger, :level` (`Anubis.Logging.should_log?/1`), and its
per-message lines are all at debug, so they are dropped; its warnings (request
errors, timeouts) still appear and carry error structs, not message bodies.
Production must stay at `:info` or above.

MCP bodies Anubis cannot decode: Anubis's transport plug logs the whole body of any
MCP message it cannot decode at error level (`MCP transport event: parse_error`, then
`MCP transport details` with `body:`), which for a malformed `tools/call` would put
its SQL or events into the log stream. `Web.MCP.Router` therefore decodes and
validates the body itself (4.3) and hands Anubis the decoded map, a path on which
Anubis does not log; rejected bodies are logged as size, reason, and a known method
name only, never caller-chosen strings.

The remaining stdout leaks above are accepted: they are bounded by error frequency
and reach only operators. `IO.puts` in `Web.JsonApi` bypasses the Logger level.

Failed authentication is not logged anywhere (4.2.4).

## 9. Known gaps

Open gaps named above, by boundary:

1. B1: on Fly, a client configured with `http://` sends its first request, key
   included, in clear before the redirect, and no HSTS header is sent (3).
2. B1: Bandit listens on every IPv4 interface, so on hosts that do not firewall the
   port, clients can bypass the edge's TLS and concurrency limit (3).
3. B1b: anyone with the tunnel token can run a connector and receive some requests;
   the connector has no destination allowlist, so administrative access to the
   operator's Cloudflare account reaches the deployment's private network (3).
4. B2: the key's length is observable through timing (4.2.1).
5. B2: the 32-byte minimum is a length policy, not an entropy check (4.2.2).
6. B2: with `GUARDIAN_ALLOW_QUERY_API_KEY=true`, keys travel in URLs (4.2.3).
7. B2: failed authentication is not logged, rate-limited, or alerted on (4.2.4).
8. B3: no bound on a query's total memory. The heap guard limits each query process's
   own heap but not ETS, native column memory, or shared binaries, and can
   overshoot; a deliberate or exotic query can still exhaust memory on every node and
   lose unpersisted events (5.2.2).
9. B3: one slow MCP call blocks other MCP requests on that machine (a query for up to
   its 30 s limit plus its schema lookup, an ingest until done) (5.2.3).
10. B3: MCP error messages can carry internal detail such as node names (5.2.4).
11. B3, B6: a corrupt segment file aborts the VM (5.2.5).
12. B3: some event shapes are slow to flatten (5.2.6).
13. B3: a segment that never stores holds its memory and is lost at shutdown (5.2.7).
14. B4: distribution traffic is unencrypted; the cookie is the only authority, with no
    member allowlist (6.5).
15. B4: the image carries a build-time cookie, used by a single node (6.5.3).
16. B5: secrets end up in any Erlang crash dump (7.2).
17. B7: caller data reaches stdout in printed errors and crash reports, and the
    `referer` header is stored verbatim (4.1.3, 8).

## 10. How this was checked

Written from the code: the routers, `Web.Auth`, `Web.Logger`, `Web.QueryParseErrors`,
`Web.QueryLog`, `Engine`, `Cluster`, `Query.Limits`, `config/runtime.exs`,
`rel/env.sh.eex`, `bin/fly-start`, `Dockerfile`, and `fly.toml` in this repository,
and the pinned dependencies `cors_plug` 3.0.3 and `anubis_mcp` 0.16.0. Regular
expressions run on OTP's `:re` through `Query.Regex`. Statements about Fly's platform
(volume encryption, private network membership, edge behavior) come from Fly's
tooling and documentation, not from Guardian's code. Where something was read from a
dependency's source rather than tested, the text says so.

When code on one of these boundaries changes, update the matching section here.

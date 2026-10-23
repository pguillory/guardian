# Guardian

Guardian is a single-tenant, self-hosted event store. Producers send it JSON events over
HTTP or MCP, and people and agents query them with a SQL-like language. It's schemaless:
any JSON object can go into any table, nested objects become dotted columns, and a
column can hold mixed types. Events land in Guardian's own columnar segment format, can
be queried as soon as they're stored, and expire after 15 days.

Guardian runs as a single node or as a cluster. Each node keeps the events it received,
and every query fans out to all connected nodes. Fly.io is the best-supported
deployment, and any set of machines that can resolve each other through DNS can form a
cluster.

Guardian is single-tenant. One API key grants full read and write access to every
table. There are no users, roles or namespaces.

Product docs: the [overview](docs/product/overview.md) (one sentence, one paragraph,
one page) and the full [product spec](docs/product/spec.md). How it's built:
[system architecture](docs/architecture/system.md). What it protects and how:
[security architecture](docs/architecture/security.md).

## Quickstart (Docker, single node)

The image targets linux/amd64. Guardian uses Hyperscan, the regex engine behind `RLIKE`
and `replace()`, and the image downloads the amd64 cloudflared, so there's no native
arm64 image.

```sh
docker build --platform linux/amd64 -t guardian .

export GUARDIAN_API_KEY="$(openssl rand -hex 32)"

docker run -d --name guardian --platform linux/amd64 \
  --stop-timeout 120 \
  -p 127.0.0.1:8080:8080 \
  -v guardian_data:/data \
  -e GUARDIAN_API_KEY \
  guardian
```

On Apple Silicon, amd64 runs under emulation, where the BEAM JIT miscompiles Mix
projects. Add `--build-arg ERL_FLAGS="+JMsingle true"` to `docker build` and
`-e ERL_FLAGS="+JMsingle true"` to `docker run`.

`--stop-timeout 120` gives Guardian time to persist its in-memory segments when the
container stops (its shutdown budget is about 110 s; Docker's default is 10 s).
Mount a volume at `/data`, or segments land in the container's writable layer and are
lost with it. The server answers `/health` only after loading every segment on its
volume, so the first check after a restart can take a while on a large volume.

```sh
curl http://127.0.0.1:8080/health

curl -s http://127.0.0.1:8080/api/json/send_events \
  -H "x-api-key: $GUARDIAN_API_KEY" -H 'content-type: application/json' \
  -d '{"table": "requests", "events": [{"path": "/", "status": 200, "timestamp": "2026-10-22 12:00:00"}]}'

curl -s http://127.0.0.1:8080/api/json/query \
  -H "x-api-key: $GUARDIAN_API_KEY" -H 'content-type: application/json' \
  -d '{"query": "SELECT status, count() FROM requests GROUP BY status"}'
```

Guardian speaks plain HTTP. Put TLS in front of it (a reverse proxy, a load balancer, or
Fly's edge) before you expose it beyond the machine; the API key travels in every
request.

The operator's console:

```sh
docker exec -it guardian /app/bin/guardian remote
```

Inside it, `Console.query("SHOW TABLES")` prints a query's rows as a table.

## Configuration

Everything is set through environment variables. Only `GUARDIAN_API_KEY` is required.

| Variable | Default | Meaning |
| --- | --- | --- |
| `GUARDIAN_API_KEY` | (required) | The one API key. At least 32 bytes; generate it with `openssl rand -hex 32`. Rotating it takes effect at restart and doesn't affect stored data. |
| `GUARDIAN_DATA_DIR` | `/data` in the image, `/root/data` for a bare release | Where segments are stored. Startup refuses a directory it can't write, so set it when running a bare release as a non-root user. On Fly it must be the mounted volume. |
| `GUARDIAN_PORT` | `8080` | The HTTP port. |
| `GUARDIAN_ALLOW_QUERY_API_KEY` | `false` | `true` also accepts the key as an `api_key` query parameter. URLs end up in logs and history more readily than headers, so leave it off unless a client can't send the `x-api-key` header. |
| `GUARDIAN_QUERY_MAX_HEAP_MB` | `256` | The heap limit for each process a query runs in. `0` turns it off. See "Known limitations". |
| `GUARDIAN_MUTABLE_SEGMENT_MAX_AGE_MS` | `3600000` | How long an in-memory segment collects events before it's handed off to disk. |
| `GUARDIAN_NODE_HOST` | (unset; `FLY_PRIVATE_IP` on Fly) | The address other nodes reach this node at. Setting it makes the node a cluster member named `guardian@<address>`. |
| `DNS_CLUSTER_QUERY` | (unset; `<app>.internal` on Fly) | A DNS name resolving to every node's IP. Nodes poll it every 5 s and connect to the peers it returns. |
| `RELEASE_COOKIE` | (required when clustered) | The Erlang distribution secret, shared by every node. It grants code execution on all of them. |
| `GUARDIAN_DIST_PORT` | (unset: a random port) | Pins the server's Erlang distribution port, so a firewall needs only that port and epmd's 4369. |
| `TUNNEL_TOKEN` | (unset) | Optional: starts a Cloudflare Tunnel connector beside Guardian (see "Optional: Cloudflare Tunnel"). |

## Deployment setups

### Single node

The quickstart above. With neither `GUARDIAN_NODE_HOST` nor `FLY_PRIVATE_IP` set, the
node is named `guardian@localhost` and Erlang distribution (epmd and the distribution
port) listens only on loopback. `bin/guardian remote` works on the machine itself, and
nothing else can reach distribution. No cookie is needed.

### A cluster on any set of machines

Give every node:

1. `GUARDIAN_NODE_HOST`: its own IP address as the other nodes see it. With DNS
   discovery it must be an IP literal written the way Erlang writes it (`10.0.0.5`,
   `fd00::5`, not an expanded or uppercase IPv6 form), and not loopback. A node that
   breaks this refuses to start rather than silently never joining. An IPv6 address
   switches distribution to IPv6.
2. `DNS_CLUSTER_QUERY`: one DNS name that resolves to every node's IP (A records for
   IPv4, AAAA for IPv6). A Kubernetes headless service works, and so does a Docker
   network alias shared by every node. A load-balancer VIP doesn't: the name must
   return each node's own address.
3. `RELEASE_COOKIE`: the same long random secret on every node
   (`openssl rand -base64 48`).
4. Its own volume. Segment IDs are per node, and nodes never share storage.

The machines must reach each other on epmd (4369) and the distribution port. Pin that
port with `GUARDIAN_DIST_PORT`.

Keep epmd and the distribution port on a private network. Anyone who can reach them
and knows the cookie can run code on every node. Distribution traffic isn't encrypted,
so events cross that network in the clear. Don't reuse a cookie and DNS name across
environments: nodes that find each other join one cluster, and every query then reads
both environments' data.

[`examples/docker-compose.yml`](examples/docker-compose.yml) shows a three-node cluster
on one Docker host: a user-defined network with fixed addresses, a shared network
alias as `DNS_CLUSTER_QUERY`, and one volume per node. It hasn't been run as part of
this repository's checks. Treat it as a starting point.

A node with `GUARDIAN_NODE_HOST` but no `DNS_CLUSTER_QUERY` is a standalone,
long-named node: it discovers nothing on its own, but it listens for distribution on
all interfaces, so it needs the cookie and the same firewalling as a cluster member.

### Fly.io

Fly is a preset of the cluster above. On a Fly machine the node host defaults to its
private IPv6 address and `DNS_CLUSTER_QUERY` to `<app>.internal`, so a cluster needs
no configuration beyond the cookie. The `Dockerfile` builds the release (including
the column, mmap and Hyperscan NIFs and the sandboxed jq worker), and `fly.toml` runs
it with:

- a volume at `/data`
- HTTPS at Fly's edge, forwarding to port 8080
- an unauthenticated `GET /health` check
- machines that never auto-stop and always restart

The `fly.toml` in this repository is the maintainer's own deployment. Before your
first deploy:

1. Set `app` to your app's name and `primary_region` to your region (for example
   `sjc`).
2. Delete the block marked "this deployment's overrides", so your deploy gets
   Guardian's defaults.
3. Adjust `[[vm]]` or the volume's `initial_size` (10 GB) if needed.

```sh
fly auth login
fly apps create <app-name>

fly secrets set --stage \
  GUARDIAN_API_KEY="$(openssl rand -hex 32)" \
  RELEASE_COOKIE="$(openssl rand -base64 48 | tr -d '\n/+=')"

fly deploy --ha=false --wait-timeout 15m \
  --build-arg GIT_COMMIT="$(git rev-parse HEAD)"
```

The first deploy creates one machine and its `guardian_data` volume. Make sure the app
has public addresses (a first `fly deploy` normally allocates them), then check it:

```sh
fly ips list
fly ips allocate-v6          # only if no v6 address is listed
fly ips allocate-v4 --shared # only if no v4 address is listed
fly status
curl https://<app-name>.fly.dev/health
fly logs
```

On Fly, a machine refuses to start unless `/data` is a mounted volume, so it can't
silently keep events on its disposable root filesystem. You can attach a custom domain
with `fly certs add <domain>`.

Later deploys run the same `fly deploy` command. With one machine, each deploy briefly
stops ingestion, because the volume attaches to only one machine: the old release stops
before the new one starts, so producers must retry. A new release that fails its health
check stops the deploy but doesn't roll back. To roll back, find the previous image with
`fly releases --image` and run `fly deploy --image <image>`. The health check allows 10
minutes for segments to load; keep `--wait-timeout` above that, and raise both if boots
get slower.

The remote console is `fly ssh console --pty -C "/app/bin/guardian remote"`. Inside it,
`Node.list()` shows the connected peers. Rotate the key with
`fly secrets set GUARDIAN_API_KEY=...`, which restarts the machine.

To scale, run `fly scale count 2`. That creates a machine and a new volume, and the
machine joins the cluster within seconds. With more than one machine:

- Deploys replace machines one at a time, so ingestion continues on the others.
- Queries miss a machine's data until it has loaded its segments.
- A query running while a machine shuts down can fail with a node error. Retry it.

Scaling down destroys a machine but leaves its volume unattached. That machine's
events drop out of queries until a machine uses that volume again.

### Optional: Cloudflare Tunnel

When the `TUNNEL_TOKEN` secret is set, the image's entry point (`bin/fly-start`)
starts a cloudflared connector beside Guardian. The connector opens an outbound
Cloudflare Tunnel, so Cloudflare Workers can reach Guardian through a Workers VPC
binding instead of the public edge. The same API key applies. Without the token, the
entry point is exactly `guardian start`. Import the token from a protected source
(`fly secrets import --stage`) rather than typing it on a command line.

## API

All `/api/json` and `/mcp` requests need the key in the `x-api-key` header, or in the
`api_key` query parameter when `GUARDIAN_ALLOW_QUERY_API_KEY=true`. Without a key, only
`GET /health` and CORS preflight (`OPTIONS`) requests to `/api/json` succeed. The JSON
API checks the key before reading the request body. With a valid key, a malformed body
gets a 400, a body over 8 MB a 413, and an unsupported content type a 415.

`POST /api/json/send_events` ingests events:

```json
{
  "table": "requests",
  "events": [{"path": "/", "status": 200}]
}
```

The response returns one result per input event, in order:

```json
{
  "status": 200,
  "results": [{"success": true, "event": {"path": "/", "status": 200}}]
}
```

Events are inserted independently:

- A failed event returns `{"success": false, "error": "..."}`, and later events
  continue.
- If a storage call fails unexpectedly, its error says the event may have been stored.
- Valid requests return 200 even if every event fails.
- Invalid tables, missing or non-list `events`, and malformed `return_keys` return 400
  with `info`, before any event is stored.
- Optional `return_keys` must be a list of strings and filters what successful events
  return. Omitting it or passing `null` returns all fields.

`POST /api/json/query` runs a query:

```json
{
  "query": "SELECT status, count() FROM requests GROUP BY status"
}
```

The MCP endpoint at `/mcp` (Streamable HTTP) exposes two tools:

- `query`: runs one SQL query and returns rows as JSON objects.
- `send_events`: ingests a `table`, an `events` list of JSON objects, and optional
  `return_keys`. Its result has the same `{status: 200, results: [...]}` shape as
  HTTP. Invalid requests return an MCP tool error before anything is stored.

For example, a Claude Code client:

```sh
claude mcp add --transport http guardian https://<your-host>/mcp \
  --header "x-api-key: $GUARDIAN_API_KEY"
```

Table names must match `[a-z_][a-z0-9_]*`, be at most 64 characters, and exclude SQL
keywords, `null`, `true`, `false`, `current_date`, `current_timestamp` and `schema`.
Use stable object keys, and put data in values (`{"customer_id": 123}`, not
`{"123": true}`). Guardian adds no timestamp: each producer stamps its own, by
convention a UTC `timestamp` string (`YYYY-MM-DD HH:MM:SS`) and a `time_ms` number.

## Built-in tables

Guardian writes some tables of its own:

- `system_stats`: Erlang VM metrics, once a second.
- `web_requests` and `web_responses`: one pair per authenticated JSON API request.
  `auth_method` says whether the key came from the header or the query parameter; the
  key itself is never recorded. MCP calls aren't logged here.
- `query_parse_errors`: one row for each query that fails to parse, over JSON or MCP.

## Query language

Guardian supports `SELECT`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`,
`SHOW TABLES` and `DESC`, along with query-time aggregations and scalar functions
(including a sandboxed `jq()`). Queries are read-only: there's no `INSERT` or
`DELETE`. The full reference is
[`lib/web/mcp/query_language.md`](lib/web/mcp/query_language.md), which MCP also
serves as the resource `guardian://query-language`.

## Known limitations

1. No replication. A node's events live only on its own volume, so a lost volume loses
   them. On Fly, volume snapshots run daily (kept 14 days per `fly.toml`).
2. One key, one principal. Every key holder can read and write everything.
3. Recent events can be lost in a crash. In-memory segments go to disk an hour after
   their first event by default, and queue or disk delays can stretch that. A hard
   crash loses what isn't on disk yet. A normal stop persists everything within the
   shutdown budget (about 110 s; Fly's `kill_timeout` is 120 s).
4. Retention is fixed: persisted segments expire after 15 days.
5. A query covers only the nodes connected when it runs. A node that's down or still
   loading its segments is silently missing from results.
6. Memory isn't fully bounded. Results are capped at 100,000 rows and about 64 MiB, and
   string functions at 16 MiB per value. `GUARDIAN_QUERY_MAX_HEAP_MB` kills any single
   query process whose Erlang heap passes the limit, but that doesn't bound a query's
   total memory:
   - GROUP BY state lives in ETS, column data in native memory, and shared binaries
     aren't counted.
   - The check runs at garbage collection, so a process can overshoot.
   - Many processes can each reach the limit.
   A heavy query can still exhaust a machine. Size the machine with headroom. A large
   `ORDER BY` without `LIMIT` sorts in one process and can hit the heap limit; narrow
   it or add a `LIMIT`.
7. During a rolling deploy across machines running different releases, queries can
   fail until every machine runs the new one. Retry them.
8. Every machine running `guardian start` with the same cookie and DNS name joins the
   cluster and its query results.

## Development

Prerequisites:

- Elixir 1.19.3 on Erlang/OTP 28.2 (the versions the image uses)
- a C toolchain
- Hyperscan headers and library: `libhyperscan-dev` on Debian/Ubuntu, or Homebrew
  `vectorscan` on macOS
- libjq: `libjq-dev`, or Homebrew `jq`
- on Linux, an x86-64 machine: `libhyperscan-dev` is x86-64 only
- on macOS, Homebrew at `/opt/homebrew` (Apple Silicon): the Hyperscan dependency and
  the jq worker build look for headers and libraries there
- `epmd`, which ships with Erlang, for the multi-node tests

```sh
mix deps.get
mix test
```

`iex -S mix` and `mix run` need `GUARDIAN_API_KEY` (32 bytes or more) in the
environment and serve HTTP on port 8080. Tests use their own fixed configuration.
Before committing, run `bin/install-git-hooks` once; the hook checks formatting,
compiles with warnings as errors, and runs the suite. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT; see [LICENSE](LICENSE). Third-party components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

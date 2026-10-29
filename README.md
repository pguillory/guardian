# Guardian

Guardian is a self-hosted event store for you and your agents. Your applications send
it JSON events over HTTP, your agents ask questions of them in SQL over MCP, and rules
can decide on each event as it arrives, sending the decision back to the application.

There's nothing to design first. A table exists once something writes to it, any JSON
object fits, nested objects become dotted columns (`user.plan`), and a new field is a
new column.

## A walkthrough

The example is a web application that tells Guardian about every request it gets,
using the Python client (see [Connecting](#connecting)).

### 1. Putting events in Guardian

```python
guardian.event("requests", {"method": "GET", "path": "/", "ip": "203.0.113.9"})
```

Any JSON object works. Then ask your agent who's been visiting the home page, and it
queries Guardian over MCP:

```sql
SELECT ip FROM requests WHERE path = '/'
```

```text
+--------------+
| ip           |
+--------------+
| 203.0.113.9  |
| 198.51.100.7 |
+--------------+
```

The queries read like SQL, with `GROUP BY`, about twenty aggregates and sixty
functions; see the [query language](lib/guardian/web/mcp/query_language.md).

### 2. Getting decisions back

Ask for fields back when you send the event, and act on them:

```python
response = guardian.event("requests", {"method": "GET", "path": "/", "ip": "203.0.113.9"},
                          returning=["is_blocked"])
if response.get("is_blocked"):
    raise PermissionError("blocked")
```

Nothing sets `is_blocked` yet, so it's `None`. Tell your agent "block
203.0.113.9", and it writes a rule for the `requests` table:

```sql
SET is_blocked = ip IN ['203.0.113.9']
```

Every event sent to `requests` now runs that rule before it's stored, and the
response carries the result: `{"is_blocked": true}` for that IP, `false` for the rest.
Changing what's blocked is now a rule change, not a deploy.

### 3. Counters and rate limits

Tell your agent "also block any IP making more than 100 requests in 10 minutes":

```sql
TRACK requests_last_10m = count() BY ip LAST '10m';
SET is_blocked = ip IN ['203.0.113.9'] OR requests_last_10m > 100
```

TRACK counts each IP's recent requests, this one included; once the count passes
100, the request is blocked. The [rules guide](docs/guides/rules.md) covers counters,
UNSET (strip a field before it's stored) and where rules are kept.

## Run it

The simplest way is Fly.io, which puts HTTPS in front of Guardian for you. The
[Fly guide](docs/guides/fly.md)'s first deploy takes a handful of `fly` commands, run
from your checkout: `fly launch` with flags, a volume, one addition to the `fly.toml`
it writes, the keys as secrets, and `fly deploy`.

Your Guardian is at `https://<app-name>.fly.dev`. Keep both keys: the ingest key goes
to your applications and can only send events; the admin key is for you and your
agents. The
[Fly guide](docs/guides/fly.md) covers addresses, scaling, rollbacks and a custom
domain.

To try it on your own machine instead, run the Docker image (linux/amd64; arm64 is
untested, see [system.md 10.1](docs/architecture/system.md#101-build)):

```sh
docker build -t guardian .

export GUARDIAN_ADMIN_API_KEY="$(openssl rand -hex 32)"
export GUARDIAN_INGEST_API_KEY="$(openssl rand -hex 32)"

docker run -d --name guardian \
  --stop-timeout 120 \
  -p 127.0.0.1:8080:8080 \
  -v guardian_data:/data \
  -e GUARDIAN_ADMIN_API_KEY \
  -e GUARDIAN_INGEST_API_KEY \
  guardian

curl http://127.0.0.1:8080/health
```

Your Guardian is then at `http://127.0.0.1:8080`. That's plain HTTP: put TLS in
front of it before you expose it beyond the machine, since a key travels in every
request. Running from source, a cluster on your own machines, and every setting are
under [Documentation](#documentation).

## Connecting

Applications send events with the insert-only ingest key. Guardian has clients for
Python, TypeScript, Elixir and Rust. In Python:

```python
import os

from guardian import Guardian

guardian = Guardian("https://guardian.example.com", api_key=os.environ["GUARDIAN_INGEST_API_KEY"])
guardian.event("requests", {"method": "GET", "path": "/", "ip": "203.0.113.9"})
```

`event` returns the fields named in `returning`, or the whole event as stored. To
query by time, add a UTC `timestamp` field as `YYYY-MM-DD HH:MM:SS`; Guardian adds
nothing to your events.

From any other language it's one HTTP request:

```sh
curl https://guardian.example.com/api/json/send_events \
  -H "x-api-key: $GUARDIAN_INGEST_API_KEY" -H 'content-type: application/json' \
  -d '{"table": "requests", "events": [{"path": "/", "ip": "198.51.100.7"}], "return_keys": ["is_blocked"]}'
```

```json
{"status": 200, "results": [{"success": true, "event": {"is_blocked": false}}]}
```

The [API reference](docs/reference/api.md) has the full request and response shapes,
batches and retries.

Agents connect to the MCP server at `/mcp` with the admin key. Claude Code:

```sh
claude mcp add --transport http guardian https://guardian.example.com/mcp \
  --header "x-api-key: $GUARDIAN_ADMIN_API_KEY"
```

Or Codex, in `~/.codex/config.toml`, reading the key from your environment:

```toml
[mcp_servers.guardian]
url = "https://guardian.example.com/mcp"
env_http_headers = { "x-api-key" = "GUARDIAN_ADMIN_API_KEY" }
```

The agent gets a `query` tool, rule tools (`list_rules`, `read_rule`, `write_rule`,
`delete_rule`), a `send_events` tool for testing, and the query language reference,
so it writes queries and rules without coaching. Every rule write is checked against
the whole rule set first, so a bad rule never goes live.

## What it isn't

Guardian stays small on purpose, and these are the trade-offs:

- Single-tenant. An admin key reads and writes every table; an insert-only ingest key
  for your applications can send events and nothing else. There are no users or
  namespaces, so it suits an operator's own systems, not analytics shared across a
  team.
- Short-lived data. Events expire after about 15 days, with no per-table retention.
  Each machine keeps its own events, with no replication, and a hard crash loses
  recent writes that haven't reached disk yet (normally up to about an hour's worth).
- Questions, not reports. A query reads one table, with no joins or subqueries, and
  there's no web UI, dashboards or alerting.

If you need long retention, high-volume log pipelines or a shared analytics product, a
dedicated analytics database or a hosted observability service will serve you better.
The details are in [Known limitations](docs/reference/limitations.md).

## Elixir callers

Elixir code running in Guardian's own VM, embedding it rather than using the client,
can ingest and query directly:

```elixir
Guardian.Engine.ingest_events("requests", [%{"path" => "/", "status" => 200}])
Guardian.Query.execute("SELECT status, count() FROM requests GROUP BY status")
# => {:ok, ["status", "count()"], [[200, 1]]}
```

Direct queries return tuples and bypass API query logging. Guardian still runs one
event store per VM with its normal supervision tree and `:guardian` application
configuration. When embedding Guardian as a Mix dependency, configure the
`:guardian` application keys in the host app: Mix does not evaluate a dependency's
`config/runtime.exs`, which translates Guardian's environment variables. See the
[configuration reference](docs/reference/configuration.md) for the release settings
and [application keys](docs/architecture/system.md#9-configuration).

## Documentation

Running it:

- [Single node](docs/guides/single-node.md): Docker in detail, Apple Silicon, TLS, the
  operator's console.
- [A cluster on any machines](docs/guides/cluster.md): DNS discovery, the cookie,
  firewalling, the Docker Compose example.
- [Fly.io](docs/guides/fly.md): the best-supported deployment, scaling, rollbacks,
  and the optional Cloudflare Tunnel.
- [Configuration](docs/reference/configuration.md): every environment variable.
- [Rules and rule storage](docs/guides/rules.md): TRACK/LOOKUP counters, SET/UNSET and rule files in a folder or an S3-compatible bucket.
- [Known limitations](docs/reference/limitations.md): durability, retention, memory,
  and cluster behavior to plan around.

Using it:

- [HTTP and MCP API](docs/reference/api.md): authentication, request and response
  shapes, table names, and Guardian's built-in tables.
- [Query language](lib/guardian/web/mcp/query_language.md).

Working on it:

- [Building and development](docs/guides/development.md): prerequisites, setup, the
  commit checks and running locally. See also [CONTRIBUTING.md](CONTRIBUTING.md).
- [Implementing query functions](docs/guides/query-functions.md): dispatch,
  implementation patterns and worked tests.
- [Storage columns](docs/architecture/storage-columns.md): native column APIs,
  metadata, usage patterns and debugging.
- Product docs: the [overview](docs/product/overview.md) (one sentence, one
  paragraph, one page) and the full [product spec](docs/product/spec.md).
- How it's built: the [system architecture](docs/architecture/system.md). What it
  protects and how: the [security architecture](docs/architecture/security.md).

## License

MIT; see [LICENSE](LICENSE). Third-party components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

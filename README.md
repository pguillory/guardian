# Guardian

Guardian is a self-hosted event store for you and your agents. Your services, scripts
and coding agents send it JSON events, and you or your agents ask questions about them
in a SQL-like language, seconds or days later.

The idea is to record what happened, with the context it happened in, and decide what
to ask later. A producer puts what it knows into the event when it sends it: the
user's plan, the request's latency, the error it hit. There's no schema to
design first and no pipeline to build, and ingestion never calls out to another
service, so a query next week sees what the producer saw at that moment.

What makes it pleasant to use:

- Schemaless. Any JSON object can go into any table. Nested objects become dotted
  columns (`user.plan`), and a column can hold mixed types. A new field is just a new
  column.
- Queryable at once. Events can be queried as soon as they're stored, in Guardian's
  own columnar format.
- A real query language. `GROUP BY`, `HAVING`, `ORDER BY`, about twenty aggregates,
  regular expressions (`RLIKE` and `replace()`), and time functions that work on
  the `timestamp` strings your producers already write.
- Agent-native. A built-in MCP endpoint gives Claude Code, Codex or any MCP client two
  tools, `send_events` and `query`, plus the full query-language reference. An agent
  can record what it does and answer questions about everything else.
- Small to run, and it scales out. One release, one required environment variable.
  Run a single node, or a cluster on any machines that can find each other through
  DNS (Fly.io is a preset). Every query fans out to every node, each node scans the
  events it received, and GROUP BY spreads its aggregation across the cluster.

Guardian is single-tenant: one API key reads and writes every table, with no users,
roles or namespaces, and events expire after 15 days. It's built for an operator's
own systems, not as a multi-user analytics product.

## What using it looks like

Send events over HTTP. Each one is any JSON object; Guardian adds nothing, so stamp
your own `timestamp`:

```sh
curl -s https://guardian.example.com/api/json/send_events \
  -H "x-api-key: $GUARDIAN_API_KEY" -H 'content-type: application/json' \
  -d '{"table": "requests", "events": [{
        "timestamp": "2026-10-23 06:40:12",
        "method": "POST", "path": "/checkout", "status": 502, "duration_ms": 3011,
        "user": {"id": 7, "plan": "free"},
        "error": "upstream_timeout"
      }]}'
```

Then query them. The results here and below come from a table of six such
requests:

```sh
curl -s https://guardian.example.com/api/json/query \
  -H "x-api-key: $GUARDIAN_API_KEY" -H 'content-type: application/json' \
  -d '{"query": "SELECT user.plan, count() AS requests, count_if(status >= 500) AS errors FROM requests GROUP BY user.plan"}'
```

```json
{"status": 200, "columns": ["user.plan", "requests", "errors"], "rows": [["pro", 4, 1], ["free", 2, 1]]}
```

The slowest endpoints over the last hour (timestamps are UTC strings by convention, so
ranges are plain comparisons):

```sql
SELECT path, count(), avg(duration_ms), max(duration_ms)
FROM requests
WHERE timestamp > date_sub(now(), INTERVAL 1 HOUR)
GROUP BY path
ORDER BY avg(duration_ms) DESC
LIMIT 10
```

```text
path                 | count() | avg(duration_ms)   | max(duration_ms)
/checkout            | 3       | 2047.6666666666667 | 3011
/search              | 1       | 640.0              | 640
/api/v2/orders/9912  | 1       | 41.0               | 41
/api/v2/orders/10007 | 1       | 12.0               | 12
```

Regular expressions with `RLIKE`:

```sql
SELECT path, status, duration_ms FROM requests WHERE path RLIKE '^/api/v[0-9]+/orders/[0-9]+$'
```

```text
path                 | status | duration_ms
/api/v2/orders/9912  | 200    | 41
/api/v2/orders/10007 | 404    | 12
```

Normalize paths with `replace()`, which takes a regular expression, and group by the
result:

```sql
SELECT replace(path, '/[0-9]+', '/:id') AS route, count(), avg(duration_ms)
FROM requests
GROUP BY route
ORDER BY count() DESC
```

```text
route              | count() | avg(duration_ms)
/checkout          | 3       | 2047.6666666666667
/api/v2/orders/:id | 2       | 26.5
/search            | 1       | 640.0
```

Name a condition once with `LET`, and pick values from the row that maximizes another
with `max_by`:

```sql
LET slow = duration_ms > 1000;
SELECT user.id, count() AS slow_requests, max_by(path, duration_ms) AS slowest_path
FROM requests
WHERE slow
GROUP BY user.id
```

`SHOW TABLES` and `DESC requests` show what's there. The full language, including
every function, is in the [query language reference](lib/web/mcp/query_language.md).

## Let your agent use it

Guardian serves MCP (Streamable HTTP) at `/mcp`. Connect Claude Code:

```sh
claude mcp add --transport http guardian https://guardian.example.com/mcp \
  --header "x-api-key: $GUARDIAN_API_KEY"
```

Or Codex, in `~/.codex/config.toml`, reading the key from your environment:

```toml
[mcp_servers.guardian]
url = "https://guardian.example.com/mcp"
env_http_headers = { "x-api-key" = "GUARDIAN_API_KEY" }
```

The agent gets two tools:

- `query` takes `sql`, one statement, and returns the rows as JSON objects.
- `send_events` takes a `table`, a list of `events`, and optional `return_keys`, and
  returns one ordered result per event.

It can also read the resource `guardian://query-language`, the same reference linked
above, so it learns the syntax without your help. A session looks like this:

> You: Checkout has been flaky for the last hour. What's going on?
>
> Agent calls `query`:
> `{"sql": "SELECT status, count(), avg(duration_ms) FROM requests WHERE path = '/checkout' AND timestamp > date_sub(now(), INTERVAL 1 HOUR) GROUP BY status"}`
>
> Guardian returns:
> `[{"avg(duration_ms)": 2980.5, "count()": 2, "status": 502}, {"avg(duration_ms)": 182.0, "count()": 1, "status": 200}]`
>
> Agent calls `query` again, to see the errors:
> `{"sql": "SELECT error, count() FROM requests WHERE path = '/checkout' AND status = 502 AND timestamp > date_sub(now(), INTERVAL 1 HOUR) GROUP BY error"}`
>
> Guardian returns:
> `[{"count()": 1, "error": "card_declined"}, {"count()": 1, "error": "upstream_timeout"}]`
>
> Agent: Two of the last hour's three checkouts failed with a 502 after about 3 s
> each: one upstream timeout and one declined card. The timeout is the one to chase.
>
> You: Log that you're rolling back checkout.
>
> Agent calls `send_events`:
> `{"table": "deploys", "events": [{"timestamp": "2026-10-23 06:41:00", "service": "checkout", "action": "rollback", "by": "claude"}]}`
>
> Guardian returns:
> `{"status": 200, "results": [{"success": true, "event": {"action": "rollback", "by": "claude", "service": "checkout", "timestamp": "2026-10-23 06:41:00"}}]}`

## Quickstart

Run a single node in Docker. The image is built in CI for linux/amd64; arm64
should build but is untested (see [the single-node guide](docs/guides/single-node.md)).

```sh
docker build -t guardian .

export GUARDIAN_API_KEY="$(openssl rand -hex 32)"

docker run -d --name guardian \
  --stop-timeout 120 \
  -p 127.0.0.1:8080:8080 \
  -v guardian_data:/data \
  -e GUARDIAN_API_KEY \
  guardian

curl http://127.0.0.1:8080/health
```

Then send an event and query it:

```sh
curl -s http://127.0.0.1:8080/api/json/send_events \
  -H "x-api-key: $GUARDIAN_API_KEY" -H 'content-type: application/json' \
  -d '{"table": "requests", "events": [{"path": "/", "status": 200, "timestamp": "2026-10-22 12:00:00"}]}'

curl -s http://127.0.0.1:8080/api/json/query \
  -H "x-api-key: $GUARDIAN_API_KEY" -H 'content-type: application/json' \
  -d '{"query": "SELECT status, count() FROM requests GROUP BY status"}'
```

Guardian speaks plain HTTP. Put TLS in front of it before you expose it beyond the
machine; the API key travels in every request.

## Documentation

Running it:

- [Single node](docs/guides/single-node.md): Docker in detail, Apple Silicon, TLS, the
  operator's console.
- [A cluster on any machines](docs/guides/cluster.md): DNS discovery, the cookie,
  firewalling, the Docker Compose example.
- [Fly.io](docs/guides/fly.md): the best-supported deployment, scaling, rollbacks,
  and the optional Cloudflare Tunnel.
- [Configuration](docs/reference/configuration.md): every environment variable.
- [Known limitations](docs/reference/limitations.md): durability, retention, memory,
  and cluster behavior to plan around.

Using it:

- [HTTP and MCP API](docs/reference/api.md): authentication, request and response
  shapes, table names, and Guardian's built-in tables.
- [Query language](lib/web/mcp/query_language.md).

Working on it:

- [Building and development](docs/guides/development.md): prerequisites and tests.
  See also [CONTRIBUTING.md](CONTRIBUTING.md).
- Product docs: the [overview](docs/product/overview.md) (one sentence, one
  paragraph, one page) and the full [product spec](docs/product/spec.md).
- How it's built: the [system architecture](docs/architecture/system.md). What it
  protects and how: the [security architecture](docs/architecture/security.md).

## License

MIT; see [LICENSE](LICENSE). Third-party components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

# Guardian

Guardian is a self-hosted event store for you and your agents. Your services and
scripts send it JSON events, and you or your agents query them in a SQL-like language,
over HTTP or MCP.

It's built for one job: keeping a record of what your own systems did, with the
context they had at the time, so you can decide later what to ask. A producer puts
what it knows into the event when it sends it: the user's plan, the request's latency,
the error it hit. Guardian stores it as sent, and a query next week sees what the
producer saw at that moment.

## Why use it

- Nothing to design first. A table exists once something writes to it, and any JSON
  object fits. Nested objects become dotted columns (`user.plan`), a new field is a new
  column, and a column can hold a number in one event and a string in the next. There
  are no schemas, mappings or index settings to plan, and no pipeline to build.
- Made for agents to query. MCP is part of the server, not a separate service beside
  it. Claude Code, Codex or any MCP client gets a `query` tool and the full
  query-language reference, so it can write queries without coaching. Your application
  code writes the events, which keeps their shape consistent.
- Queries read like SQL. `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY` and `LIMIT`, about
  twenty aggregates and sixty scalar functions, including regular expressions and time
  functions that work on the `timestamp` strings your producers already write.
- Decisions on the way in. Rules compute fields on each event before it's stored
  (`SET is_blocked = risk_score > 0.9`) and strip fields you never want kept
  (`UNSET password`). The sender gets the computed fields back in the same response,
  so it can act on them at once.
- One thing to run. One Docker image, one required environment variable, and no other
  services to stand up. When one machine isn't enough, add machines that find each
  other through DNS (Fly.io is a preset); every query fans out to all of them, and each
  scans the events it received.

## What it isn't

Guardian stays small on purpose, and these are the trade-offs:

- Single-tenant. One API key reads and writes every table. There are no users, roles
  or namespaces, so it suits an operator's own systems, not analytics shared across a
  team.
- Short-lived data. Events expire after about 15 days, with no per-table retention.
  Each machine keeps its own events, with no replication, and a hard crash loses
  recent writes that haven't reached disk yet (normally up to about an hour's worth).
- Questions, not reports. A query reads one table, with no joins or subqueries, and
  there's no web UI, dashboards or alerting.

If you need long retention, high-volume log pipelines or a shared analytics product, a
dedicated analytics database or a hosted observability service will serve you better.
The details are in [Known limitations](docs/reference/limitations.md).

## What using it looks like

Send events over HTTP. Each one is any JSON object; Guardian adds nothing, so stamp
your own UTC `timestamp` as `YYYY-MM-DD HH:MM:SS`, without an offset:

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

The slowest endpoints over the last hour (timestamps are UTC strings by convention,
so ranges are plain comparisons). Time arithmetic accepts only `YYYY-MM-DD HH:MM:SS`;
offsets, `T`, `Z`, fractional seconds and other formats return null:

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
every function, is in the [query language reference](lib/guardian/web/mcp/query_language.md).

## Rules: decide as events arrive

A rule file holds SET, UNSET, TRACK and LOOKUP statements for one table. Every event sent to that
table runs them before it's stored, and the sender can ask for the results in the
same response. Here is `logins/blocking.gsql`:

```sql
-- Decide on every login as it arrives.
SET is_blocked = risk_score > 0.9;
SET is_suspicious = true WHERE lower(message) RLIKE 'wire transfer|gift card';
-- Never store the password, whatever the client sends.
UNSET password
```

A login comes in, asking for the decision back:

```sh
curl -s https://guardian.example.com/api/json/send_events \
  -H "x-api-key: $GUARDIAN_API_KEY" -H 'content-type: application/json' \
  -d '{"table": "logins", "return_keys": ["is_blocked", "is_suspicious"], "events": [{
        "timestamp": "2026-10-23 06:40:12", "user": "dana", "ip": "203.0.113.9",
        "risk_score": 0.97, "message": "Send the WIRE TRANSFER today", "password": "hunter2"
      }]}'
```

```json
{"status": 200, "results": [{"success": true, "event": {"is_blocked": true, "is_suspicious": true}}]}
```

The login service refuses Dana on the spot. The computed fields are stored like any
other, and the password never was. After two more logins:

```sql
SELECT user, risk_score, is_blocked, is_suspicious, password FROM logins ORDER BY timestamp
```

```text
user | risk_score | is_blocked | is_suspicious | password
dana | 0.97       | true       | true          | null
lee  | 0.12       | false      | null          | null
kim  | 0.35       | false      | true          | null
```

Expressions are the query language's, missing fields are null, and nothing has to be
declared first. Rules live in a folder or an S3-compatible bucket such as Cloudflare
R2, and an agent manages them with the MCP tools `list_rules`, `read_rule`,
`write_rule` and `delete_rule`. Every write is checked against the whole rule set
first (syntax, a field defined two ways, rules that depend on each other in a
circle), so a bad rule never goes live. The details are in the
[product spec](docs/product/spec.md#51-rules).

Counters let a producer react to recent activity:

```sql
-- logins/rate.gsql
TRACK logins_last_hour = count() BY ip LAST '1h';
LOOKUP previous_logins = logins_last_hour BY ip;
SET busy = logins_last_hour >= 50
```

Ask for `logins_last_hour`, `previous_logins` and `busy` in `return_keys`. On the
50th login for an IP, TRACK returns 50 and LOOKUP returns 49, regardless of statement
order. LOOKUP can also read a named counter on another table with `FROM table`.
Queries see the values stored on each event, not today's live counts.

Counters are approximate and ephemeral. Window buckets can include almost one
extra bucket of older events; restarts, eviction and cluster changes lose state.
Counter failures return the aggregate's result over no rows (0 for counts) and
ingestion continues. A later rule/storage failure can leave increments behind; unkeyed retries
count again. These are advisory signals, not durable enforcement limits. See the
[rules guide](docs/guides/rules.md#counters-with-track-and-lookup) for operators,
grouping, window semantics, safe edits and memory configuration.

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

The agent gets a `query` tool, which takes `sql`, one statement, and returns the rows
as JSON objects. There's also a `send_events` tool, the MCP twin of the HTTP endpoint,
which is handy for testing; in normal use your application code sends the
events and the agent only reads them. The rule tools let the agent write and change
rules.

The agent can also read the resource `guardian://query-language`, the same reference
linked above, so it learns the syntax without your help. A session looks like this:

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

## Quickstart

Run a single node in Docker. The supported image architecture is linux/amd64; arm64
is untested (see [system.md 10.1](docs/architecture/system.md#101-build)).

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

## Elixir callers

Guardian's modules live under `Guardian.*`, including `Guardian.Web.*`, so they
can coexist with an application's own `Query`, `Storage` or `Web` modules. With
Guardian running, Elixir code can ingest and query directly:

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

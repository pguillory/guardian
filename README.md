# Guardian

Guardian is a self-hosted event store for you and your agents. Your applications send
it JSON events over HTTP, your agents ask questions of them in SQL over MCP, and rules
can decide on each event as it arrives, sending the decision back to the application.

There's nothing to design first. A table exists once something writes to it, any JSON
object fits, nested objects become dotted columns (`user.plan`), and a new field is a
new column. It's built for recent events: they expire after about 15 days (see
[Known limitations](docs/reference/limitations.md)).

## A walkthrough

The example is a web application that tells Guardian about every request it gets.

### 1. Putting events in Guardian

This code goes into your application. We'll show Python, but use whatever language
you use. Any JSON object works as an event. `send_event` is a few lines you write
yourself (see [Sending events from your code](#sending-events-from-your-code)).

```python
send_event("requests", {"method": "GET", "path": "/", "ip": "203.0.113.9"})
```

Then ask your agent a question: who's been visiting the homepage? It queries Guardian
over MCP with a SQL-like language:

```sql
SELECT ip FROM requests WHERE path = '/'
```

| ip           |
|--------------|
| 203.0.113.9  |
| 198.51.100.7 |

The language has `GROUP BY`, about twenty aggregates and sixty functions; see the
[query language](lib/guardian/web/mcp/query_language.md).

### 2. Getting decisions back

Back in your application code, ask for fields back from Guardian and act on them:

```python
response = send_event("requests", {"method": "GET", "path": "/", "ip": "203.0.113.9"},
                      returning=["is_blocked"])
if response["is_blocked"]:
    raise PermissionError("blocked")
```

Nothing says it's blocked yet, so `is_blocked` is `None`. Tell your agent "block
203.0.113.9", and it writes a rule for the `requests` table:

```sql
SET is_blocked = true WHERE ip = '203.0.113.9'
```

Every event sent to `requests` now runs that rule before it's stored, and the
response carries the result: `{"is_blocked": true}` for that IP, `null` for the rest.
Changing what's blocked is now a rule change, not a deploy.

### 3. Counters and rate limits

Tell your agent "also block any IP making more than 100 requests in 10 minutes". It
sends Guardian a new rule over MCP, in the same SQL-like language, replacing the first
one:

```sql
TRACK requests_last_10m = count() BY ip LAST '10m';

SET is_blocked = true WHERE ip = '203.0.113.9' OR requests_last_10m > 100
```

The [rules guide](docs/guides/rules.md) covers counters and where rules are kept.

## How to run it

### 1. Deploy on Fly

Follow the [Fly guide](docs/guides/fly.md) to get it deployed. You'll come back with
an app name (your URL is `https://<app>.fly.dev`), an ingest key and an admin key.
To run it on your own machine with Docker instead, see the
[single-node guide](docs/guides/single-node.md).

### 2. Send an event

```sh
curl https://<app>.fly.dev/api/json/send_events \
  -H "x-api-key: <ingest-key>" -H 'content-type: application/json' \
  -d '{"table": "requests", "events": [{"method": "GET", "path": "/", "ip": "198.51.100.7"}]}'
```

```json
{"status":200,"results":[{"success":true,"event":{"ip":"198.51.100.7","method":"GET","path":"/"}}]}
```

### 3. Connect Claude Code

```sh
claude mcp add --transport http guardian https://<app>.fly.dev/mcp \
  --header "x-api-key: <admin-key>"
```

Claude Code keeps the key in its own configuration in your home directory. Don't add
`--scope project`, which would write it into the project's `.mcp.json`.

Your agent can now query Guardian, write rules and send test events. It gets the query
language reference too, so it writes queries and rules without coaching, and every
rule is checked before it goes live.

## Sending events from your code

Sending an event is the one HTTP request above, so a few lines make a helper. In
Python, with [requests](https://requests.readthedocs.io/) (`pip install requests`):

```python
import os

import requests

GUARDIAN_URL = "https://<app>.fly.dev/api/json/send_events"
HEADERS = {"x-api-key": os.environ["GUARDIAN_INGEST_API_KEY"]}


def send_event(table, event, returning=None):
    body = {"table": table, "events": [event], "return_keys": returning}
    response = requests.post(GUARDIAN_URL, json=body, headers=HEADERS)
    response.raise_for_status()
    [result] = response.json()["results"]
    if not result["success"]:
        raise RuntimeError(result["error"])
    return result["event"]
```

Your application reads the ingest key from its environment. `send_event` returns the
fields named in `returning`, or the whole event as stored, and raises if Guardian
refuses the request or the event.

To query by time, add a UTC `timestamp` field as `YYYY-MM-DD HH:MM:SS`; Guardian adds
nothing to your events. The [API reference](docs/reference/api.md) has the full
request and response shapes, batches and retries.

## Elixir callers

Elixir code running in Guardian's own VM, embedding it rather than calling it over
HTTP, can ingest and query directly:

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

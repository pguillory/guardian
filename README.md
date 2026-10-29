# Guardian

Guardian is a self-hosted event store for you and your agents. Your applications send
it JSON events over HTTP, your agents ask questions of them in SQL over MCP, and rules
can decide on each event as it arrives, sending the decision back to the application.

There's nothing to design first. A table exists once something writes to it, any JSON
object fits, nested objects become dotted columns (`user.plan`), and a new field is a
new column. It's built for recent events: they expire after about 15 days (see
[Known limitations](docs/reference/limitations.md)).

## A walkthrough

The example is a web application that tells Guardian about every request it gets,
through a small helper function you write yourself (see
[Sending events from your code](#sending-events-from-your-code)).

### 1. Putting events in Guardian

```python
event("requests", {"method": "GET", "path": "/", "ip": "203.0.113.9"})
```

Any JSON object works. Then ask your agent who's been visiting the home page, and it
queries Guardian over MCP:

```sql
SELECT ip FROM requests WHERE path = '/'
```

| ip           |
|--------------|
| 203.0.113.9  |
| 198.51.100.7 |

The queries read like SQL, with `GROUP BY`, about twenty aggregates and sixty
functions; see the [query language](lib/guardian/web/mcp/query_language.md).

### 2. Getting decisions back

Ask for fields back when you send the event, and act on them:

```python
response = event("requests", {"method": "GET", "path": "/", "ip": "203.0.113.9"},
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

### 1. Deploy it on Fly.io

Fly.io puts HTTPS in front of Guardian for you. From your checkout of this repository,
with an app name and a region of your choice (the [Fly guide](docs/guides/fly.md)
explains each command, and covers addresses, scaling, rollbacks and a custom domain):

```sh
fly auth login
fly launch --no-deploy --yes --no-github-workflow \
  --name <app-name> --region <region> --ha=false --auto-stop off \
  --vm-size shared-cpu-1x --vm-memory 1024 \
  --volume guardian_data:/data:initial_size=10gb
fly volumes create guardian_data --app <app-name> --region <region> \
  --size 10 --snapshot-retention 14 --yes

# Once only: the settings flyctl has no command for.
printf 'kill_signal = "SIGTERM"\nkill_timeout = 150\n\n' | cat - fly.toml > fly.toml.new &&
  mv fly.toml.new fly.toml

cat >> fly.toml <<'EOF'

[deploy]
  strategy = "rolling"
  max_unavailable = 1
  wait_timeout = "15m"

[http_service.concurrency]
  type = "requests"
  soft_limit = 200
  hard_limit = 250

[[http_service.checks]]
  method = "GET"
  path = "/health"
  interval = "15s"
  timeout = "5s"
  grace_period = "1m"

[[restart]]
  policy = "always"
EOF

# Once only: your keys, saved to a file only you can read, then set as secrets.
export GUARDIAN_ADMIN_API_KEY="$(openssl rand -hex 32)"
export GUARDIAN_INGEST_API_KEY="$(openssl rand -hex 32)"

(umask 077; set -o noclobber
 printf 'GUARDIAN_ADMIN_API_KEY=%s\nGUARDIAN_INGEST_API_KEY=%s\n' \
   "$GUARDIAN_ADMIN_API_KEY" "$GUARDIAN_INGEST_API_KEY" > ~/guardian-<app-name>.env) &&
printf 'GUARDIAN_ADMIN_API_KEY=%s\nGUARDIAN_INGEST_API_KEY=%s\nRELEASE_COOKIE=%s\n' \
  "$GUARDIAN_ADMIN_API_KEY" "$GUARDIAN_INGEST_API_KEY" \
  "$(openssl rand -base64 48 | tr -d '\n/+=')" |
  fly secrets import --stage --app <app-name>

fly deploy --ha=false --build-arg GIT_COMMIT="$(git rev-parse HEAD)"
```

Your Guardian is at `https://<app-name>.fly.dev`. The ingest key goes to your
applications and can only send events; the admin key is for you and your agents, and
for nothing else. In a new shell, load both again with
`set -a; . ~/guardian-<app-name>.env; set +a`. To run it on your own machine with
Docker instead, see the [single-node guide](docs/guides/single-node.md).

### 2. Send an event

```sh
curl https://<app-name>.fly.dev/api/json/send_events \
  -H "x-api-key: $GUARDIAN_INGEST_API_KEY" -H 'content-type: application/json' \
  -d '{"table": "requests", "events": [{"method": "GET", "path": "/", "ip": "198.51.100.7"}]}'
```

```json
{"status":200,"results":[{"success":true,"event":{"ip":"198.51.100.7","method":"GET","path":"/"}}]}
```

### 3. Connect Claude Code

Agents connect to the MCP server at `/mcp` with the admin key:

```sh
claude mcp add --transport http guardian https://<app-name>.fly.dev/mcp \
  --header "x-api-key: $GUARDIAN_ADMIN_API_KEY"
```

Claude Code keeps the key in its own configuration in your home directory. Don't add
`--scope project`, which would write it into the project's `.mcp.json`.

The agent gets a `query` tool, rule tools (`list_rules`, `read_rule`, `write_rule`,
`delete_rule`), a `send_events` tool for testing, and the query language reference,
so it writes queries and rules without coaching. Every rule write is checked against
the whole rule set first, so a bad rule never goes live.

## Sending events from your code

Sending an event is the one HTTP request above, so a few lines of your own make a
helper. In Python, with only the standard library:

```python
import json
import os
import urllib.request

GUARDIAN_URL = "https://<app-name>.fly.dev"
API_KEY = os.environ["GUARDIAN_INGEST_API_KEY"]


def event(table, fields, returning=None):
    body = {"table": table, "events": [fields]}
    if returning is not None:
        body["return_keys"] = returning
    request = urllib.request.Request(
        f"{GUARDIAN_URL}/api/json/send_events",
        data=json.dumps(body).encode(),
        headers={"x-api-key": API_KEY, "content-type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        result = json.load(response)["results"][0]
    if not result["success"]:
        raise RuntimeError(result["error"])
    return result["event"]
```

`event` returns the fields named in `returning`, or the whole event as stored. A
request Guardian refuses raises `urllib.error.HTTPError`. In JavaScript (Node 18 or
later):

```js
const GUARDIAN_URL = "https://<app-name>.fly.dev";
const API_KEY = process.env.GUARDIAN_INGEST_API_KEY;

export async function event(table, fields, returning) {
  const body = { table, events: [fields] };
  if (returning !== undefined) body.return_keys = returning;
  const response = await fetch(`${GUARDIAN_URL}/api/json/send_events`, {
    method: "POST",
    headers: { "x-api-key": API_KEY, "content-type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error(`Guardian answered ${response.status}`);
  const [result] = (await response.json()).results;
  if (!result.success) throw new Error(result.error);
  return result.event;
}
```

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

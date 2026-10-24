# HTTP and MCP API

## Authentication

All `/api/json` and `/mcp` requests need the key in the `x-api-key` header, or in the
`api_key` query parameter when `GUARDIAN_ALLOW_QUERY_API_KEY=true`. Without a key, only
`GET /health` and CORS preflight (`OPTIONS`) requests to `/api/json` succeed. The JSON
API checks the key before reading the request body. With a valid key, a malformed body
gets a 400, a body over 8 MB a 413, and an unsupported content type a 415.

## Sending events

`POST /api/json/send_events` ingests events:

```json
{
  "table": "requests",
  "events": [{"path": "/", "status": 200}]
}
```

The response to a new batch returns one result per input event, in order (a
[matching keyed retry](#retrying-a-batch) gets a receipt instead):

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
- Invalid tables, missing or non-list `events`, and malformed `return_keys` or
  `idempotency_key` return 400 with `info`, before any event is stored.
- Optional `return_keys` must be a list of strings and filters what successful events
  return. Omitting it or passing `null` returns all fields; a listed field the event
  doesn't have comes back as `null`.
- If the table has [rules](../product/spec.md#51-rules), each event runs them first and
  the response shows the event as stored, so `return_keys` is how a sender reads a
  computed field. An event whose rules fail isn't stored and gets an error naming the
  rule file and line (or the table, if its rules ran over their time or memory limit
  or are invalid).

Table names must match `[a-z_][a-z0-9_]*`, be at most 64 characters, and exclude SQL
keywords, `null`, `true`, `false`, `current_date`, `current_timestamp` and `schema`.
Use stable object keys, and put data in values (`{"customer_id": 123}`, not
`{"123": true}`). Guardian adds no timestamp: each producer stamps its own, by
convention a UTC `timestamp` string (`YYYY-MM-DD HH:MM:SS`) and a `time_ms` number.
Private arrival metadata drives counter windows; it is never automatically stored
or taken from the event's timestamp fields.

### Counter decisions in the response

[TRACK and LOOKUP rules](../guides/rules.md#counters-with-track-and-lookup) return
their output through the same `return_keys` mechanism:

```sql
TRACK hits = count() BY ip LAST '1h';
LOOKUP previous_hits = hits BY ip;
SET busy = hits >= 50
```

With these rules on `logins`, request `return_keys: ["hits", "previous_hits", "busy"]`.
The 50th login in a group returns 50, 49 and true. Successful TRACK includes the
current event; LOOKUP excludes it. Queries read the stored historical outputs.
Counter failures still return successful ingest with missing results (0 for counts,
null for sum/min/max/avg); final UNSETs continue. WHERE false/null preserves an
incoming output, so only applied statements produce trusted computed values.
Counters are approximate and ephemeral, with boundary overcount and state loss;
use them as advisory signals, not durable limits.

An increment can survive a later rule or storage failure. There is no rollback or
internal event replay. Unkeyed retries count again. A completed matching keyed
retry skips counters but returns only a receipt, without computed decisions.

### Retrying a batch

Supply an optional `idempotency_key` in the JSON body (or the MCP tool arguments):

```json
{
  "table": "requests",
  "events": [{"path": "/", "status": 200}],
  "idempotency_key": "request-7dbe8a"
}
```

The key must be a nonempty UTF-8 string of at most 128 bytes. Omitted or `null`
keeps ordinary ingestion, including duplicates on retry. Keys are scoped to a
table on one node, shared by HTTP and MCP. Use a unique key for each logical batch.

The first call returns the usual `results`. For ten seconds after it completes,
a matching retry gets this receipt without running rules or storing events again:

```json
{"status": 200, "duplicate": true, "failed_events": 0}
```

The receipt has no `results` array or computed event values. `failed_events` counts
the original batch's failed events, including any whose storage outcome was
uncertain. Mixed and all-failed batches are remembered too: a receipt acknowledges
processing, not that every event was stored. To retry known failures, send only the
failed events under a new key. An uncertain failure may have stored its event;
resubmitting it under a new key can duplicate it.

Reuse the same key only with matching decoded JSON values for `events` and
`return_keys`: object field order is ignored, but number types (`1` versus `1.0`)
and list order matter. Omitted and null `return_keys` match. Changed contents get
HTTP 409 with `info` (or an MCP tool error). Invalid keys get HTTP 400/tool errors
before any event is stored or key claimed.

While the original is running, a retry that reaches the ingest handler gets HTTP
409/tool error saying it is in flight; retry the same request promptly. MCP calls
share one server and may first queue behind the original or time out. If the
original aborts unexpectedly, retries get an unknown-outcome conflict for ten
seconds: events may have been stored. Guardian never automatically retries them.

Protection is best effort. Retries must reach the same node; another node has no
record of the key. Restarts (including a receipt-coordinator restart) forget keys.
The cache holds at most 10,000 keys across tables. At capacity it evicts the oldest
completed entries, which can shorten the ten-second window. If every slot is still
in flight, or the coordinator is unavailable or slow, valid ingestion proceeds
without protection and logs a fixed info message. Expiry, eviction, fail-open
operation and restarts can allow duplicates; this is not an exactly-once guarantee.

## Querying

`POST /api/json/query` runs a query:

```json
{
  "query": "SELECT status, count() FROM requests GROUP BY status"
}
```

The response carries the column names and the rows:

```json
{"status": 200, "columns": ["status", "count()"], "rows": [[200, 1]]}
```

Guardian supports `SELECT`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`,
`SHOW TABLES` and `DESC`, along with query-time aggregations and scalar functions
(including `RLIKE` and `replace()` with Perl-compatible regular expressions). Queries
are read-only: there's no `INSERT` or `DELETE`. The full reference is
[`lib/web/mcp/query_language.md`](../../lib/web/mcp/query_language.md), which MCP also
serves as the resource `guardian://query-language`.

## MCP

The MCP endpoint at `/mcp` (Streamable HTTP) exposes these tools:

- `query`: runs one SQL query, given as `sql`, and returns rows as JSON objects.
- `send_events`: ingests a `table`, an `events` list of JSON objects, and optional
  `return_keys` and `idempotency_key`. Its result has the same ordered results or
  duplicate receipt as HTTP (see [Retrying a batch](#retrying-a-batch)). Invalid
  requests and idempotency conflicts return an MCP tool error.
- `list_rules`, `read_rule`, `write_rule`, `delete_rule`: manage rule files
  (`table` and `name`, plus `source` to write). A write is checked against the whole
  rule set and refused, with the errors, if it would add one; a saved write returns
  `saved: true`, any errors the set already had, and any nodes that didn't confirm
  reloading. SET, UNSET, TRACK and LOOKUP syntax and safe counter edits are in the
  [rules guide](../guides/rules.md). The served `guardian://query-language` resource
  includes the rule reference too.

For example, a Claude Code client:

```sh
claude mcp add --transport http guardian https://<your-host>/mcp \
  --header "x-api-key: $GUARDIAN_API_KEY"
```

## Built-in tables

Guardian writes some tables of its own:

- `system_stats`: Erlang VM metrics, once a second.
- `web_requests` and `web_responses`: one pair per authenticated JSON API request.
  `auth_method` says whether the key came from the header or the query parameter; the
  key itself isn't recorded, with one exception: the `referer` header is stored
  verbatim, so a referring URL that carries `?api_key=` records the key (see the
  [security architecture](../architecture/security.md)). MCP calls aren't logged here.
- `query_parse_errors`: one row for each query that fails to parse, over JSON or MCP.
- `queries`: one row for every query run over JSON or MCP, written on the machine that
  received it: the query text (first 16 KiB), `interface` (`http` or `mcp`), start
  `timestamp`, `duration_ms`, `row_count`, and `outcome` (`ok` or `error`, with
  `error_kind` and `error`). The key and request headers are never recorded. Fields
  are listed in [spec section 8](../product/spec.md#8-built-in-tables).

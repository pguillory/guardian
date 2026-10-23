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

Table names must match `[a-z_][a-z0-9_]*`, be at most 64 characters, and exclude SQL
keywords, `null`, `true`, `false`, `current_date`, `current_timestamp` and `schema`.
Use stable object keys, and put data in values (`{"customer_id": 123}`, not
`{"123": true}`). Guardian adds no timestamp: each producer stamps its own, by
convention a UTC `timestamp` string (`YYYY-MM-DD HH:MM:SS`) and a `time_ms` number.

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

The MCP endpoint at `/mcp` (Streamable HTTP) exposes two tools:

- `query`: runs one SQL query, given as `sql`, and returns rows as JSON objects.
- `send_events`: ingests a `table`, an `events` list of JSON objects, and optional
  `return_keys`. Its result has the same `{status: 200, results: [...]}` shape as
  HTTP. Invalid requests return an MCP tool error before anything is stored.

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

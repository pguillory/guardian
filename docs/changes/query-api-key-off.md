# query-api-key-off: keys only in the header

## Problem

`GUARDIAN_ALLOW_QUERY_API_KEY=true` let any key travel as the `api_key` URL query
parameter, where it ends up in client logs, shell history, proxy logs and browser
history. It was off by default; the maintainer's deployment kept it on only until
evidence showed nothing used it. Keeping the option meant two code paths in the key
check, an extra failure mode (an undecodable query string answered 400 or 414 before
the key check), a log note, a recorded `auth_method` column, and a setting.

## Change

1. A key is accepted only in the first `x-api-key` header, on both `/api/json` and
   `/mcp`, for all three keys. The query string is never decoded for a key: a request
   without the header gets 401 `api_key required`, whatever its query string,
   including `?api_key=<a valid key>` and query strings that cannot be decoded.
2. `GUARDIAN_ALLOW_QUERY_API_KEY` no longer exists. If still set it is ignored, like
   any unknown variable, so a deployment that sets it keeps booting.
3. `web_requests` and `web_responses` no longer record `auth_method`; it would always
   be `header`. `auth_key` stays. Older rows keep their column.
4. The `/mcp` log line for a query-parameter key is gone; the legacy-key line stays.
5. `Guardian.Web.Auth.check_conn/2` returns `{:ok, key}` instead of
   `{:ok, method, key}`, and no longer returns `{:error, {:invalid_query, status}}`.
   The JSON API's 400/414 "invalid query string" after a valid key is unchanged
   (Plug.Parsers).

Evidence: in the maintainer's deployment, `web_requests.auth_method` showed no
query-parameter use and no `/mcp` query-key log line appeared, and no known client
configuration puts a key in the URL. A client configured somewhere not checked (for
example a hosted connector that cannot send headers) would now get 401.

## Product spec impact

Section 3 item 1 says a key is read only from the header, never the URL; item 5
drops the query-key 400/414 case; item 6 drops the setting from the boot errors;
item 7 drops `auth_method` and the query-key log line. Section 8 item 2 drops
`auth_method` from `web_requests`, noting older rows may have it. The one-page
overview says the key goes only in the header.

## Validation

`test/guardian/web/auth_test.exs` and `auth_routes_test.exs` check that a valid key
in the URL is refused like no key on both routers, and that an undecodable query
string without a header is a plain 401. `json_api_test.exs` checks the same for
`send_events` and that `web_requests` rows have no `auth_method`.
`test/guardian/config/runtime_test.exs` checks that the old variable is ignored.

## Deploy notes

After deploying, a request that sends its key only as `?api_key=` gets 401
`api_key required`. If MCP traffic in `queries` or ingest traffic in `web_requests`
drops after the deploy, suspect a client that sent the key in the URL; it must move
to the `x-api-key` header.

defmodule Web.JsonApi do
  @moduledoc """
  JSON HTTP API for Guardian event ingestion and queries.

  All endpoints require the API key (see "Authentication"). CORSPlug runs first
  and answers CORS preflight `OPTIONS` requests with 204 before authentication.
  Plug.Parsers reads and decodes the body only after the key check, so a request
  without a valid key gets 401 (or 400 for an undecodable query string) without its
  body being read; with a key, malformed JSON gets 400, a body over 8 MB 413, and a
  declared non-JSON content type 415. The unauthenticated liveness check is
  `GET /health` in `Web.MainRouter`, outside this API.

  ## Authentication

  All requests must include the API key in a header:

      x-api-key: your_api_key_here

  Only when query keys are allowed (`GUARDIAN_ALLOW_QUERY_API_KEY=true`, off by
  default) may it come as a query parameter instead, `?api_key=your_api_key_here`;
  the header takes precedence if both are present. `Web.Auth.check_conn/1` decides. A
  valid key grants access to the whole event store.

  ## Endpoints

  ### POST /send_events

  Insert events independently into a table, returning one outcome per input in order.

  **Request Body**:
  ```json
  {
    "table": "events",
    "events": [
      {"customer_id": 123, "action": "login", "ip": "1.2.3.4"}
    ],
    "return_keys": ["customer_id", "approved"]  // optional
  }
  ```

  **Response**:
  ```json
  {
    "status": 200,
    "results": [
      {"success": true, "event": {"customer_id": 123}},
      {"success": false, "error": "event is not a JSON object"}
    ]
  }
  ```

  The `return_keys` parameter filters each successful result's event. If omitted or
  null, all fields are returned. It must otherwise be a list of strings.

  Optional `idempotency_key` is null or a nonempty UTF-8 string of at most 128
  bytes, scoped to one table on this node. A matching retry within ten seconds of
  completion returns `{status: 200, duplicate: true, failed_events: N}` without
  results or another write. Changed events/return_keys, pending claims or unknown
  outcomes return 409 with info. Capacity, expiry, unavailability, restarts and
  other nodes can lose protection; see `docs/reference/api.md` for the contract.

  Ingestion is not atomic: an event failure does not stop later events. A failure
  after storage starts says the event may have been stored. Details are logged.
  Valid requests return 200 even if every event fails. Invalid tables, missing or
  non-list events, and malformed return_keys or idempotency_key return 400 before
  any event is stored.

  ### POST /query

  Execute one SQL statement, optionally preceded by LET statements. The query is
  resolved like an MCP query, so `SELECT *`, SHOW TABLES, and DESC are supported.

  **Request Body**:
  ```json
  {
    "query": "SELECT ip, count() FROM requests WHERE status = 404 GROUP BY ip LIMIT 10"
  }
  ```

  **Response**:
  ```json
  {
    "status": 200,
    "columns": ["ip", "count()"],
    "rows": [
      ["1.2.3.4", 5],
      ["5.6.7.8", 3]
    ]
  }
  ```

  The `columns` field contains the column labels, and `rows` contains the result rows.

  ## Error Responses

  **401 Unauthorized**:
  ```json
  {"status": 401, "info": "api_key required"}
  ```

  **400 Bad Request** (`send_events` invalid table, events, return_keys or idempotency_key):
  ```json
  {"status": 400, "info": "invalid table name \"a.b\": ..."}
  ```

  **409 Conflict** (`send_events` changed, in-flight or uncertain idempotency key):
  ```json
  {"status": 409, "info": "idempotency_key is still in flight; retry the same request promptly"}
  ```

  **400 Bad Request** (the `query` body is not a JSON object with a string `query`):
  ```json
  {"status": 400, "info": "the body must be a JSON object with a string \"query\""}
  ```

  **400 Bad Request** (`query` resolves to zero or several statements):
  ```json
  {"status": 400, "info": "Only single-statement queries are supported"}
  ```

  **400 Bad Request** (`query` fails with a `Query.Error`, such as a resource limit or
  a regular expression over its backtracking limit; `info` says what to change):
  ```json
  {"status": 400, "info": "..."}
  ```

  Other query errors, such as parse errors, return 500. Parse errors are also recorded
  in the `query_parse_errors` table, and every query, whatever its outcome, in the
  `queries` table; recording never changes the response.

  **400 Bad Request** (a query string that cannot be decoded: invalid UTF-8, or
  nesting deeper than 32; checked before the key when there is no `x-api-key`
  header):
  ```json
  {"status": 400, "info": "invalid query string"}
  ```

  **404 Not Found**:
  ```json
  {"status": 404}
  ```

  **500 Internal Server Error**:
  ```json
  {"status": 500}
  ```

  ## Future Direction

  This API is a proof-of-concept. Future versions will:
  - Improve ingestion and query error responses
  - Expand MCP integration for event analysis

  See `ARCHITECTURE.md` for API architecture details.
  """

  use Plug.ErrorHandler
  use Plug.Router

  # CORS preflight is answered before authentication; the body is read and parsed only
  # after it, so an anonymous client cannot make the server read or decode up to 8 MB.
  plug(CORSPlug)
  plug(:auth)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    query_string_length: 1_000_000
  )

  plug(:match)
  plug(Web.Logger)
  plug(:dispatch)

  defp send_json_resp(conn, status, json) do
    resp_body = [Jason.encode!(json) | "\n"]

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, resp_body)
  end

  defp auth(conn, _opts) do
    case Web.Auth.check_conn(conn) do
      {:ok, method} ->
        put_private(conn, :guardian_auth_method, method)

      {:error, :unauthorized} ->
        send_json_resp(conn, 401, %{status: 401, info: "unauthorized"})
        |> halt()

      {:error, :missing} ->
        send_json_resp(conn, 401, %{status: 401, info: "api_key required"})
        |> halt()

      {:error, {:invalid_query, status}} ->
        send_json_resp(conn, status, %{status: status, info: "invalid query string"})
        |> halt()
    end
  end

  post "/send_events" do
    case Web.Ingest.send_events(conn.body_params) do
      {:ok, result} ->
        send_json_resp(conn, 200, result)

      {:error, message} ->
        send_json_resp(conn, 400, %{status: 400, info: message})

      {:error, status, message} ->
        send_json_resp(conn, status, %{status: status, info: message})
    end
  end

  post "/query" do
    case conn.body_params do
      %{"query" => query_string} when is_binary(query_string) ->
        run_query(conn, query_string)

      # A missing or non-string query, a non-object body, or no content type (so no
      # body was parsed). The body is not echoed or logged.
      _ ->
        info = ~s(the body must be a JSON object with a string "query")
        send_json_resp(conn, 400, %{status: 400, info: info})
    end
  end

  # Runs like MCP (`Query.execute/2`). Every query is recorded in
  # queries; parse failures also in query_parse_errors, and reraised unchanged. A
  # failure of the query itself (statement count, or a `Query.Error` while running) is
  # a 400; other exceptions are 500s.
  defp run_query(conn, query_string) do
    caller_fun = fn -> Web.QueryParseErrors.http_caller(conn) end

    case Web.Query.execute(query_string, caller_fun) do
      {:ok, columns, rows} ->
        send_json_resp(conn, 200, %{status: 200, columns: columns, rows: rows})

      {:error, info} ->
        send_json_resp(conn, 400, %{status: 400, info: info})
    end
  end

  match _ do
    send_json_resp(conn, 404, %{status: 404})
  end

  # A query string Plug cannot decode (invalid UTF-8, nesting deeper than 32), raised
  # by Plug.Parsers after a valid key header (without a header, the key check answers
  # it with the same body). Its status is 400, or 414 over the parser's length limit
  # (Bandit's request-line limit, or HTTP/2's header-block limit, rejects that before
  # Plug runs). Nothing is printed.
  def handle_errors(conn, %{kind: :error, reason: %Plug.Conn.InvalidQueryError{} = error}) do
    status = Plug.Exception.status(error)
    send_json_resp(conn, status, %{status: status, info: "invalid query string"})
  end

  # Body failures (after authentication): a fixed message, nothing printed, and no
  # echo of the body.
  def handle_errors(conn, %{kind: :error, reason: %Plug.Parsers.ParseError{}}) do
    send_json_resp(conn, 400, %{status: 400, info: "malformed JSON body"})
  end

  def handle_errors(conn, %{kind: :error, reason: %Plug.Parsers.RequestTooLargeError{}}) do
    send_json_resp(conn, 413, %{status: 413, info: "request body over 8 MB"})
  end

  def handle_errors(conn, %{kind: :error, reason: %Plug.Parsers.UnsupportedMediaTypeError{}}) do
    info = "unsupported content type; send application/json"
    send_json_resp(conn, 415, %{status: 415, info: info})
  end

  def handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    IO.puts(Exception.format(kind, reason, stack))
    send_json_resp(conn, 500, %{status: 500})
  end
end

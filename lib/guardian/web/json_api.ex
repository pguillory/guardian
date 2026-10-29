defmodule Guardian.Web.JsonApi do
  @moduledoc """
  JSON HTTP API for Guardian event ingestion. Its one endpoint is `POST
  /send_events`; queries and rules go through MCP (`Guardian.Web.MCP.Router`).

  Every request needs an API key (see "Authentication"). CORSPlug runs first
  and answers CORS preflight `OPTIONS` requests with 204 before authentication.
  Plug.Parsers reads and decodes the body only after the key check, so a request
  without a valid key gets 401 (or 403 for the ingest key on a path that needs full
  access) without its
  body being read; with a key, malformed JSON gets 400, a body over 8 MB 413, and a
  declared non-JSON content type 415. The unauthenticated liveness check is
  `GET /health` in `Guardian.Web.MainRouter`, outside this API.

  ## Authentication

  All requests must include an API key in a header:

      x-api-key: your_api_key_here

  A key in the URL (`?api_key=...`) is never accepted. `Guardian.Web.Auth.check_conn/2`
  decides.
  `POST /send_events` accepts the insert-only ingest key (`GUARDIAN_INGEST_API_KEY`) as
  well as the full-access admin key (`GUARDIAN_ADMIN_API_KEY`) and the deprecated
  `GUARDIAN_API_KEY`. Any other path needs a full-access key, so the ingest key gets
  403 there.

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

  ## Error Responses

  **401 Unauthorized**:
  ```json
  {"status": 401, "info": "api_key required"}
  ```

  **403 Forbidden** (the ingest key on any path but `POST /send_events`):
  ```json
  {"status": 403, "info": "this key can only send events"}
  ```

  **400 Bad Request** (`send_events` invalid table, events, return_keys or idempotency_key):
  ```json
  {"status": 400, "info": "invalid table name \"a.b\": ..."}
  ```

  **409 Conflict** (`send_events` changed, in-flight or uncertain idempotency key):
  ```json
  {"status": 409, "info": "idempotency_key is still in flight; retry the same request promptly"}
  ```

  **400 Bad Request** (a query string that cannot be decoded: invalid UTF-8, or
  nesting deeper than 32; checked only after a valid key, so without one it is 401):
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

  See `ARCHITECTURE.md` for API architecture details.
  """

  use Plug.Router
  require Logger

  # Plug.ErrorHandler reraises after answering, so Bandit logs the original
  # exception and its arguments. Contain JSON application failures here instead.
  def call(conn, opts) do
    super(conn, opts)
  rescue
    error in Plug.Conn.WrapperError ->
      respond_to_error(error.conn, error.kind, error.reason, error.stack, false)
  catch
    kind, reason -> respond_to_error(conn, kind, reason, __STACKTRACE__, true)
  end

  # Let Bandit handle transport/protocol failures (including disconnects and read
  # timeouts) with its own status, stream cleanup and quiet logging policy.
  defp respond_to_error(_conn, :error, %module{} = reason, stack, _stale_conn?)
       when module in [
              Bandit.TransportError,
              Bandit.HTTPError,
              Bandit.HTTP2.Errors.StreamError,
              Bandit.HTTP2.Errors.ConnectionError,
            ] do
    :erlang.raise(:error, reason, stack)
  end

  defp respond_to_error(conn, kind, reason, stack, stale_conn?) do
    reason = Exception.normalize(kind, reason, stack)

    # Mirror Plug.ErrorHandler's sent marker handling. Once sent, headers cannot
    # disable keep-alive on a stale adapter; a safe replacement failure lets Bandit
    # close the connection without receiving the original reason or stack.
    receive do
      {:plug_conn, :sent} ->
        send(self(), {:plug_conn, :sent})
        message = log_error(kind, reason, stack)
        :erlang.raise(:error, %RuntimeError{message: message}, [])
    after
      0 ->
        # Before routing, no WrapperError carries the latest body-reader state.
        # HTTP/1 must close rather than try to drain bytes already consumed by the
        # parser. HTTP/2 completes/resets its individual stream without draining.
        conn =
          if stale_conn? and get_http_protocol(conn) != :"HTTP/2" do
            put_resp_header(conn, "connection", "close")
          else
            conn
          end

        handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) |> halt()
    end
  end

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
  plug(Guardian.Web.Logger)
  plug(:dispatch)

  defp send_json_resp(conn, status, json) do
    resp_body = [Jason.encode!(json) | "\n"]

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, resp_body)
  end

  defp auth(conn, _opts) do
    case Guardian.Web.Auth.check_conn(conn, required_access(conn)) do
      {:ok, key} ->
        put_private(conn, :guardian_auth_key, key)

      {:error, :unauthorized} ->
        send_json_resp(conn, 401, %{status: 401, info: "unauthorized"})
        |> halt()

      {:error, :missing} ->
        send_json_resp(conn, 401, %{status: 401, info: "api_key required"})
        |> halt()

      {:error, :forbidden} ->
        send_json_resp(conn, 403, %{status: 403, info: "this key can only send events"})
        |> halt()
    end
  end

  # The ingest key is accepted for sending events and nothing else: every other path
  # and method, including any route added later, needs a full-access key.
  defp required_access(%Plug.Conn{method: "POST", path_info: ["send_events"]}) do
    :ingest
  end

  defp required_access(_conn) do
    :full
  end

  post "/send_events" do
    case Guardian.Web.Ingest.send_events(conn.body_params) do
      {:ok, result} ->
        send_json_resp(conn, 200, result)

      {:error, message} ->
        send_json_resp(conn, 400, %{status: 400, info: message})

      {:error, status, message} ->
        send_json_resp(conn, status, %{status: status, info: message})
    end
  end

  match _ do
    send_json_resp(conn, 404, %{status: 404})
  end

  # Kept public for direct redaction coverage; no longer a Plug.ErrorHandler callback.
  @doc false
  # A query string Plug cannot decode (invalid UTF-8, nesting deeper than 32), raised
  # by Plug.Parsers after a valid key header (without one, the request already got
  # 401). Its status is 400, or 414 over the parser's length limit
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
    log_error(kind, reason, stack)
    send_json_resp(conn, 500, %{status: 500})
  end

  defp log_error(kind, reason, stack) do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    failure = Guardian.Failure.kind(kind, reason, stack)
    message = "JSON API failure kind=#{failure} id=#{id}"
    Logger.error(message)
    message
  end
end

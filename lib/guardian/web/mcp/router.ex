defmodule Guardian.Web.MCP.Router do
  @moduledoc """
  Router for MCP (Model Context Protocol) server.

  Handles authentication and forwards requests to the Anubis MCP server.
  Uses the same key check as the JSON API (`Guardian.Web.Auth.check_conn/2`): the
  `x-api-key` header only. Every request needs the full-access admin key; the
  insert-only ingest key gets 403.
  """

  use Plug.Router

  @session_header "mcp-session-id"

  # Same body limit as the JSON API; Anubis's own transport timeout for reading it.
  @max_body_bytes 8_000_000
  @read_timeout_ms 30_000

  plug(:auth)
  plug(:reject_unknown_session)
  plug(:reject_get)
  plug(:decode_body)
  plug(:require_session)
  plug(:drop_protocol_version)
  plug(:answer_inline)
  plug(:match)
  plug(:dispatch)

  # Every MCP request needs a full-access key, checked before the session lookup and
  # body decoding, including requests on an existing session. Once checked, the key is
  # dropped: Anubis keeps the request's headers in its session frame and in the call
  # it logs on a timeout, and nothing after this plug reads it.
  defp auth(conn, _opts) do
    case Guardian.Web.Auth.check_conn(conn, :full) do
      {:ok, _key} ->
        Guardian.Web.Auth.drop_api_key(conn)

      {:error, :unauthorized} ->
        send_json_error(conn, 401, %{error: "unauthorized"})

      {:error, :missing} ->
        send_json_error(conn, 401, %{error: "api_key required"})

      {:error, :forbidden} ->
        send_json_error(conn, 403, %{error: "this key can only send events"})
    end
  end

  # The Streamable HTTP spec requires 404 for an unknown session, so the client starts
  # a new one, e.g. after a restart or Anubis's 30-minute idle expiry. Anubis 2.x
  # answers 404 itself too, but with a different JSON-RPC body (code -32600 and a
  # random id); existing clients may look for -32001, so the router
  # answers first. It also rejects initialize naming an unknown session, which Anubis
  # would serve under the caller's chosen ID.
  defp reject_unknown_session(conn, _opts) do
    case named_session(conn) do
      {:ok, session_id} ->
        if known_session?(session_id) do
          conn
        else
          session_not_found(conn)
        end

      :none ->
        conn
    end
  end

  # Same rule as Anubis: exactly one non-empty value names a session.
  defp named_session(conn) do
    case Plug.Conn.get_req_header(conn, @session_header) do
      [session_id] when session_id != "" -> {:ok, session_id}
      _ -> :none
    end
  end

  # A session is known if Anubis's registry has a live process for it. Anubis 2.x
  # starts a session only for initialize and sets up its protocol version before
  # answering, so a client never holds the ID of a session that is not ready.
  # Anubis.Server.Registry.Local is the registry Anubis uses for Streamable HTTP
  # unless a server configures another; recheck on an Anubis upgrade.
  defp known_session?(session_id) do
    registry = Anubis.Server.Registry.registry_name(Guardian.Web.MCP.Server)
    match?({:ok, _pid}, Anubis.Server.Registry.Local.lookup_session(registry, session_id))
  end

  # Guardian offers no server-push stream: GET gets 405, which the Streamable HTTP spec
  # allows ("does not offer an SSE stream at this endpoint"). Every result comes back
  # in its POST response, and Guardian sends no server-initiated messages. Anubis 0.16
  # sent results down a registered GET stream it never noticed had dropped, so calls
  # hung; 2.x keeps POST results on the POST, but a GET stream would only hold a
  # connection open for nothing. Runs after the session check, so a GET naming an
  # unknown session still gets the spec's 404.
  defp reject_get(%Plug.Conn{method: "GET"} = conn, _opts) do
    error = %{
      jsonrpc: "2.0",
      id: nil,
      error: %{code: -32000, message: "Method not allowed: Guardian offers no server-push stream"},
    }

    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> send_json_error(405, error)
  end

  defp reject_get(conn, _opts) do
    conn
  end

  # Reads and validates a POST body before Anubis sees it, with an 8 MB limit (Anubis
  # reads without one and fails on a larger body) and one JSON object per request.
  # Given an already decoded `body_params`, Anubis skips its own decoding and only
  # revalidates the map. Rejections are answered, not logged. Recheck on an Anubis
  # upgrade.
  defp decode_body(%Plug.Conn{method: "POST"} = conn, _opts) do
    case Plug.Conn.read_body(conn, length: @max_body_bytes, read_timeout: @read_timeout_ms) do
      {:ok, body, conn} when byte_size(body) <= @max_body_bytes ->
        case decode_message(body) do
          {:ok, message} ->
            %{conn | body_params: message}

          {:error, code} ->
            reject_body(conn, 400, code)
        end

      {:ok, _body, conn} ->
        reject_body(conn, 413, -32600)

      {:more, _partial, conn} ->
        reject_body(conn, 413, -32600)

      {:error, _reason} ->
        reject_body(conn, 400, -32700)
    end
  end

  defp decode_body(conn, _opts) do
    conn
  end

  # Any POST other than initialize must name a session. 0.16 answered one without a
  # session ID by starting a throwaway session ("Server not initialized"); 2.x answers
  # 404 with its own body. The router sends the same 404 as for an unknown session, so
  # clients see one shape. Runs after decoding, which it needs to tell initialize apart.
  #
  # One exception: `server/discover`, the probe newer clients (Anubis 2.x among them)
  # send before `initialize`. Validation lets it through only with an id and valid
  # stateless `_meta` (it does not check that a request carries no `result` or
  # `error`). Guardian serves only 2025-03-26, so it answers "Method not found" with
  # HTTP 200: the client then falls back to `initialize`, where a 404 makes Anubis's
  # client log four error lines first.
  defp require_session(%Plug.Conn{method: "POST", body_params: message} = conn, _opts) do
    cond do
      named_session(conn) != :none -> conn
      message["method"] == "initialize" -> conn
      message["method"] == "server/discover" -> method_not_found(conn, message["id"])
      true -> session_not_found(conn)
    end
  end

  defp require_session(conn, _opts) do
    conn
  end

  # Guardian serves exactly one protocol version (2025-03-26, see Guardian.Web.MCP.Server),
  # so the MCP-Protocol-Version header carries nothing it acts on. Anubis 2.x answers 400
  # when the header names a version the server does not serve; 0.16 ignored it, and so
  # does Guardian. Revisit if Guardian ever serves a second version.
  defp drop_protocol_version(conn, _opts) do
    Plug.Conn.delete_req_header(conn, "mcp-protocol-version")
  end

  # Anubis 2.x answers a POST whose Accept header includes text/event-stream with a
  # one-event SSE stream. Guardian has always answered every POST inline as
  # application/json, and existing clients may send both types and parse the body as
  # JSON, so the router asks Anubis for JSON whenever the client accepts it (in any of
  # its Accept headers). A client that does not accept JSON keeps its headers and gets
  # Anubis's 406.
  defp answer_inline(%Plug.Conn{method: "POST"} = conn, _opts) do
    accept = conn |> Plug.Conn.get_req_header("accept") |> Enum.join(",")

    if String.contains?(accept, "application/json") do
      Plug.Conn.put_req_header(conn, "accept", "application/json")
    else
      conn
    end
  end

  defp answer_inline(conn, _opts) do
    conn
  end

  defp decode_message(body) do
    case Jason.decode(body) do
      {:ok, message} when is_map(message) ->
        case validate_message(message) do
          :ok -> {:ok, message}
          :error -> {:error, -32600}
        end

      {:ok, _not_an_object} ->
        {:error, -32600}

      {:error, _} ->
        {:error, -32700}
    end
  end

  # Anubis's validation raises on some shapes (a string or list `params`); treat that
  # as invalid without formatting the exception, which would carry the message.
  defp validate_message(message) do
    case Anubis.MCP.Message.validate_message(message) do
      {:ok, _validated} -> :ok
      {:error, _} -> :error
    end
  rescue
    # The third-party validator raises on some bad input.
    _ -> :error
  end

  defp reject_body(conn, status, code) do
    message =
      case code do
        -32700 -> "Parse error"
        -32600 when status == 413 -> "Invalid Request: body over 8 MB"
        -32600 -> "Invalid Request"
      end

    error = %{jsonrpc: "2.0", id: nil, error: %{code: code, message: message}}
    send_json_error(conn, status, error)
  end

  defp method_not_found(conn, id) do
    error = %{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "Method not found"}}
    send_json_error(conn, 200, error)
  end

  defp session_not_found(conn) do
    error = %{jsonrpc: "2.0", id: nil, error: %{code: -32001, message: "Session not found"}}
    send_json_error(conn, 404, error)
  end

  # Every response this router sends itself: a JSON body (no trailing newline), then
  # halt, so nothing after the plug runs.
  defp send_json_error(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  forward("/",
    to: Anubis.Server.Transport.StreamableHTTP.Plug,
    init_opts: [server: Guardian.Web.MCP.Server]
  )
end

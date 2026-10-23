defmodule Web.MCP.Router do
  @moduledoc """
  Router for MCP (Model Context Protocol) server.

  Handles authentication and forwards requests to the Anubis MCP server.
  Uses the same authentication as the JSON API (`Web.Auth.check_conn/1`): the
  `x-api-key` header, or the `api_key` query parameter only when
  `GUARDIAN_ALLOW_QUERY_API_KEY=true`.
  """

  use Plug.Router
  require Logger

  @session_header "mcp-session-id"

  # Same body limit as the JSON API; Anubis's own transport timeout for reading it.
  @max_body_bytes 8_000_000
  @read_timeout_ms 30_000

  # Methods named in our logs. Any other method string is caller-chosen body content,
  # logged only as "other".
  @known_methods ~w(
    initialize notifications/initialized ping tools/list tools/call resources/list
    resources/read resources/templates/list prompts/list prompts/get logging/setLevel
    completion/complete notifications/cancelled notifications/progress
    notifications/roots/list_changed server/discover
  )

  plug(:auth)
  plug(:reject_unknown_session)
  plug(:reject_get)
  plug(:decode_body)
  plug(:match)
  plug(:dispatch)

  defp auth(conn, _opts) do
    case Web.Auth.check_conn(conn) do
      {:ok, :header} ->
        conn

      # MCP requests are not recorded in web_requests, so a query-parameter key is
      # logged here instead (never the key itself), at most once a minute, as evidence
      # for whether GUARDIAN_ALLOW_QUERY_API_KEY is still needed.
      {:ok, :query} ->
        Web.Auth.note_query_key_use("/mcp")
        conn

      {:error, :unauthorized} ->
        send_json_error(conn, 401, %{error: "unauthorized"})

      {:error, :missing} ->
        send_json_error(conn, 401, %{error: "api_key required"})

      {:error, {:invalid_query, status}} ->
        send_json_error(conn, status, %{error: "invalid query string"})
    end
  end

  # Anubis 0.16 treats an unknown session ID as a new, uninitialized session and answers
  # 200 "Server not initialized". The Streamable HTTP spec requires 404 so the client
  # starts a new session, e.g. after a restart or Anubis's idle-session expiry.
  defp reject_unknown_session(conn, _opts) do
    case Plug.Conn.get_req_header(conn, @session_header) do
      # Same rule as Anubis: exactly one non-empty value names a session.
      [session_id] when session_id != "" ->
        if known_session?(session_id) do
          conn
        else
          error = %{
            jsonrpc: "2.0",
            id: nil,
            error: %{code: -32001, message: "Session not found"},
          }

          send_json_error(conn, 404, error)
        end

      _ ->
        conn
    end
  end

  # A session is known if its process is live and has handled initialize. Anubis sets
  # protocol_version before it answers initialize, so a client never holds an ID that
  # fails this. A session Anubis recreated lazily (an expiry racing this check, or a
  # restarted session process) has none, so its client gets 404 rather than being
  # stuck on "Server not initialized". Anubis.Server.Registry and Session are internal
  # to Anubis 0.16; recheck on upgrade.
  defp known_session?(session_id) do
    case Anubis.Server.Registry.whereis_server_session(Web.MCP.Server, session_id) do
      nil -> false
      pid -> Anubis.Server.Session.get(pid).protocol_version != nil
    end
  catch
    :exit, _ -> false
  end

  # Guardian offers no server-push stream: GET gets 405, which the Streamable HTTP spec
  # allows ("does not offer an SSE stream at this endpoint"). Anubis 0.16, while a
  # session has a GET stream registered, answers each request POST with 202 and sends
  # the result down that stream instead (against the spec, which forbids responses on
  # the GET stream). Anubis never schedules its keepalive, so a stream the client has
  # dropped stays registered, results vanish, and calls hang until the client times
  # out. With no stream, every result comes back in its POST response. Runs after the
  # session check, so a GET naming an unknown session still gets the spec's 404.
  # Recheck on an Anubis upgrade.
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

  defp reject_get(conn, _opts), do: conn

  # Reads and validates a POST body before Anubis sees it. Anubis 0.16 logs the whole
  # body of a message it cannot decode, at error level, which would put a malformed
  # call's SQL or events into the log stream; it also crashes on a body over its read
  # limit or one that decodes to several messages. Given an already decoded
  # `body_params`, Anubis skips its own decoding and only revalidates the map, without
  # logging. Rejections log size, reason, and a known method name only.
  # Recheck on an Anubis upgrade.
  defp decode_body(%Plug.Conn{method: "POST"} = conn, _opts) do
    case Plug.Conn.read_body(conn, length: @max_body_bytes, read_timeout: @read_timeout_ms) do
      {:ok, body, conn} when byte_size(body) <= @max_body_bytes ->
        case decode_message(body) do
          {:ok, message} ->
            %{conn | body_params: message}

          {:error, code, reason, method} ->
            log_rejected(reason, byte_size(body), method)
            reject_body(conn, 400, code)
        end

      {:ok, body, conn} ->
        log_rejected(:too_large, byte_size(body), nil)
        reject_body(conn, 413, -32600)

      {:more, partial, conn} ->
        log_rejected(:too_large, byte_size(partial), nil)
        reject_body(conn, 413, -32600)

      {:error, reason} ->
        log_rejected({:read_failed, reason}, 0, nil)
        reject_body(conn, 400, -32700)
    end
  end

  defp decode_body(conn, _opts), do: conn

  defp decode_message(body) do
    case Jason.decode(body) do
      {:ok, message} when is_map(message) ->
        method = known_method(message)

        case validate_message(message) do
          :ok -> {:ok, message}
          :error -> {:error, -32600, :invalid_message, method}
        end

      {:ok, _not_an_object} ->
        {:error, -32600, :not_an_object, nil}

      {:error, _} ->
        {:error, -32700, :invalid_json, nil}
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
    _ -> :error
  catch
    _kind, _reason -> :error
  end

  defp known_method(%{"method" => method}) when method in @known_methods, do: method
  defp known_method(%{"method" => _}), do: "other"
  defp known_method(_message), do: nil

  defp log_rejected(reason, size, method) do
    method = if method, do: " method=#{method}", else: ""

    Logger.warning("MCP request body rejected: #{inspect(reason)} (#{size} bytes)#{method}")
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
    init_opts: [server: Web.MCP.Server]
  )
end

defmodule Guardian.Test.MCPHTTP do
  @moduledoc """
  Raw MCP requests through `Guardian.Web.MainRouter` with `Plug.Test`, for tests that
  pin the wire: status codes, headers and exact JSON-RPC bodies. Requests carry the
  admin key and, by default, the headers a typical JSON-parsing MCP client sends
  (`content-type: application/json`, `accept: application/json, text/event-stream`).

  Each call runs in the calling process, so concurrent requests need their own
  processes (`Task.async/1`). Use `Guardian.Test.MCPClient` for tests that only need a
  working client.
  """

  import ExUnit.Assertions

  @api_key Application.compile_env!(:guardian, :admin_api_key)
  @accept "application/json, text/event-stream"

  @doc """
  Sends one request. `body` is a map (JSON-encoded), a binary (sent as is) or nil.
  `headers` are added after the admin key; `accept` replaces the default Accept
  header, and nil sends none.
  """
  def request(method, body, headers \\ [], accept \\ @accept) do
    body =
      cond do
        is_binary(body) -> body
        body == nil -> ""
        true -> Jason.encode!(body)
      end

    conn =
      Plug.Test.conn(method, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = if accept, do: Plug.Conn.put_req_header(conn, "accept", accept), else: conn

    [{"x-api-key", @api_key} | headers]
    |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    |> Guardian.Web.MainRouter.call(nil)
  end

  @doc """
  Opens a session the way a minimal MCP client does (initialize with protocol
  2025-03-26, then notifications/initialized) and returns its ID.
  """
  def open_session(client_name \\ "mcp-http-test") do
    conn =
      request(:post, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-03-26",
          capabilities: %{},
          clientInfo: %{name: client_name, version: "1"},
        },
      })

    assert conn.status == 200
    assert [session_id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")

    conn =
      request(:post, %{jsonrpc: "2.0", method: "notifications/initialized"}, session(session_id))

    assert conn.status == 202
    session_id
  end

  @doc "The header naming a session."
  def session(session_id) do
    [{"mcp-session-id", session_id}]
  end

  @doc "Calls a tool on a session; returns the conn."
  def call_tool(session_id, id, name, arguments) do
    request(
      :post,
      %{
        jsonrpc: "2.0",
        id: id,
        method: "tools/call",
        params: %{name: name, arguments: arguments},
      },
      session(session_id)
    )
  end

  @doc """
  Asserts a tool call answered 200 with inline JSON and a successful result, and
  returns the result's content text decoded as JSON.
  """
  def tool_json!(conn, id) do
    assert conn.status == 200
    assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert %{"id" => ^id, "result" => result} = Jason.decode!(conn.resp_body)
    refute result["isError"], "tool error: #{inspect(result)}"
    assert %{"content" => [%{"type" => "text", "text" => text}]} = result
    Jason.decode!(text)
  end

  @doc "Sends `notifications/cancelled` for request `id` on a session; returns the conn."
  def cancel(session_id, id) do
    request(
      :post,
      %{jsonrpc: "2.0", method: "notifications/cancelled", params: %{requestId: id}},
      session(session_id)
    )
  end

  @doc "The live process Anubis runs for a session, or nil."
  def session_pid(session_id) do
    registry = Anubis.Server.Registry.registry_name(Guardian.Web.MCP.Server)

    case Anubis.Server.Registry.Local.lookup_session(registry, session_id) do
      {:ok, pid} -> pid
      {:error, :not_found} -> nil
    end
  end
end

defmodule Guardian.Web.MCP.SessionTest do
  # The MCP Streamable HTTP spec requires 404 for an unknown session ID, so clients
  # re-initialize after a server restart or session expiry.
  use ExUnit.Case, async: false

  @api_key Application.compile_env!(:guardian, :api_key)

  defp mcp(method, body, headers, accept \\ "application/json, text/event-stream") do
    body = if body, do: Jason.encode!(body), else: ""

    conn =
      Plug.Test.conn(method, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", accept)

    headers
    |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    |> Guardian.Web.MainRouter.call(nil)
  end

  defp authed(headers) do
    [{"x-api-key", @api_key} | headers]
  end

  defp initialize do
    conn =
      mcp(
        :post,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            protocolVersion: "2025-06-18",
            capabilities: %{},
            clientInfo: %{name: "session-test", version: "0"},
          },
        },
        authed([])
      )

    assert conn.status == 200
    assert [session_id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")
    assert session_id != ""

    conn =
      mcp(
        :post,
        %{jsonrpc: "2.0", method: "notifications/initialized"},
        authed([{"mcp-session-id", session_id}])
      )

    assert conn.status == 202
    # Anubis handles the notification asynchronously. Wait for it, because closing the
    # session first would crash Anubis's server process (an Anubis 0.16 race).
    wait_until_initialized(session_id)
    session_id
  end

  defp wait_until_initialized(session_id, retries \\ 100) do
    pid = Anubis.Server.Registry.whereis_server_session(Guardian.Web.MCP.Server, session_id)

    cond do
      pid == nil ->
        flunk("session #{session_id} has no process")

      Anubis.Server.Session.get(pid).initialized ->
        :ok

      retries > 0 ->
        Process.sleep(10)
        wait_until_initialized(session_id, retries - 1)

      true ->
        flunk("session #{session_id} never initialized")
    end
  end

  defp tools_list(session_id) do
    mcp(
      :post,
      %{jsonrpc: "2.0", id: 2, method: "tools/list"},
      authed([{"mcp-session-id", session_id}])
    )
  end

  defp assert_session_not_found(conn) do
    assert conn.status == 404
    assert %{"error" => %{"message" => "Session not found"}} = Jason.decode!(conn.resp_body)
  end

  test "an unknown session ID gets 404 on POST, GET, and DELETE" do
    headers = authed([{"mcp-session-id", "bogus-session"}])

    assert_session_not_found(mcp(:post, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, headers))
    assert_session_not_found(mcp(:get, nil, headers))
    assert_session_not_found(mcp(:delete, nil, headers))

    # A notification previously got a silent 202.
    assert_session_not_found(
      mcp(:post, %{jsonrpc: "2.0", method: "notifications/initialized"}, headers)
    )
  end

  test "a rejected session ID does not create a session" do
    headers = authed([{"mcp-session-id", "never-created"}])
    assert_session_not_found(mcp(:post, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, headers))
    refute Anubis.Server.Registry.whereis_server_session(Guardian.Web.MCP.Server, "never-created")
  end

  test "initialize with a stale session ID gets 404" do
    conn =
      mcp(
        :post,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            protocolVersion: "2025-06-18",
            capabilities: %{},
            clientInfo: %{name: "session-test", version: "0"},
          },
        },
        authed([{"mcp-session-id", "stale-session"}])
      )

    assert_session_not_found(conn)
  end

  test "a session Anubis recreated without initialize gets 404" do
    # What Anubis does when an expiry races the router's check: it recreates the
    # session under the same ID, uninitialized.
    session_id = "recreated-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Anubis.Server.Session.Supervisor.create_session(
        Anubis.Server.Registry,
        Guardian.Web.MCP.Server,
        session_id
      )

    assert_session_not_found(tools_list(session_id))

    Anubis.Server.Session.Supervisor.close_session(
      Anubis.Server.Registry,
      Guardian.Web.MCP.Server,
      session_id
    )

    refute Process.alive?(pid)
  end

  test "a session closed by DELETE is unknown afterwards" do
    session_id = initialize()
    assert mcp(:delete, nil, authed([{"mcp-session-id", session_id}])).status == 200
    assert_session_not_found(tools_list(session_id))
  end

  test "authentication runs before the session check" do
    conn =
      mcp(:post, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, [
        {"x-api-key", "wrong"},
        {"mcp-session-id", "bogus-session"},
      ])

    assert conn.status == 401
  end

  test "a live session works, and after it is lost the client can start a new one" do
    session_id = initialize()

    conn = tools_list(session_id)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    refute Map.has_key?(body, "error")
    assert %{"result" => %{"tools" => [_ | _]}} = body

    # Drop the session through Anubis's idle-expiry path, as a restart or expiry would.
    pid = Anubis.Server.Registry.whereis_server_session(Guardian.Web.MCP.Server, session_id)
    assert is_pid(pid)
    ref = Process.monitor(pid)

    send(
      Anubis.Server.Registry.whereis_server(Guardian.Web.MCP.Server),
      {:session_expired, session_id}
    )

    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert_session_not_found(tools_list(session_id))

    new_session_id = initialize()
    assert new_session_id != session_id
    conn = tools_list(new_session_id)
    assert conn.status == 200
    assert %{"result" => %{"tools" => [_ | _]}} = Jason.decode!(conn.resp_body)
  end

  defp tools_call_query(session_id, sql) do
    mcp(
      :post,
      %{
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: %{name: "query", arguments: %{sql: sql}},
      },
      authed([{"mcp-session-id", session_id}])
    )
  end

  defp assert_query_tool_works(session_id) do
    conn = tools_call_query(session_id, "SELECT 1 AS one")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    refute Map.has_key?(body, "error"), "tools/call failed: #{inspect(body["error"])}"
    assert %{"result" => %{"content" => [%{"text" => text}]} = result} = body
    refute result["isError"]
    assert Jason.decode!(text) == [%{"one" => 1}]
  end

  defp close_session(session_id, how) do
    pid = Anubis.Server.Registry.whereis_server_session(Guardian.Web.MCP.Server, session_id)
    ref = Process.monitor(pid)

    case how do
      :delete ->
        assert mcp(:delete, nil, authed([{"mcp-session-id", session_id}])).status == 200

      :expire ->
        send(
          Anubis.Server.Registry.whereis_server(Guardian.Web.MCP.Server),
          {:session_expired, session_id}
        )
    end

    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    wait_until_server_forgot(session_id)
  end

  # Anubis's server process handles a DELETEd session's DOWN asynchronously, removing
  # it from its sessions map and clearing the frame in the same step. Idle expiry
  # removes it before the session stops.
  defp wait_until_server_forgot(session_id, retries \\ 100) do
    state = :sys.get_state(Anubis.Server.Registry.whereis_server(Guardian.Web.MCP.Server))

    cond do
      not Map.has_key?(state.sessions, session_id) ->
        state

      retries > 0 ->
        Process.sleep(10)
        wait_until_server_forgot(session_id, retries - 1)

      true ->
        flunk("server never processed the end of session #{session_id}")
    end
  end

  defp read_query_language(session_id) do
    mcp(
      :post,
      %{
        jsonrpc: "2.0",
        id: 4,
        method: "resources/read",
        params: %{uri: "guardian://query-language"},
      },
      authed([{"mcp-session-id", session_id}])
    )
  end

  # Anubis 0.16 keeps runtime-registered tools and resources in the shared server
  # frame's private map, and wipes that map when a tracked session it served last ends
  # (DELETE). Other live sessions then got "Tool not found: query" until some client
  # re-initialized. Idle expiry never
  # wiped it; it is covered as the neighboring path.
  defp assert_works_first(:query, session_id) do
    assert_query_tool_works(session_id)
  end

  defp assert_works_first(:tools_list, session_id) do
    conn = tools_list(session_id)
    assert %{"result" => %{"tools" => tools}} = Jason.decode!(conn.resp_body)

    assert Enum.map(tools, & &1["name"]) == [
             "delete_rule",
             "list_rules",
             "query",
             "read_rule",
             "send_events",
             "write_rule",
           ]
  end

  defp assert_works_first(:resources_read, session_id) do
    conn = read_query_language(session_id)
    assert conn.status == 200

    assert %{"result" => %{"contents" => [%{"text" => "# " <> _}]}} =
             Jason.decode!(conn.resp_body)
  end

  defp server_frame_private do
    :sys.get_state(Anubis.Server.Registry.whereis_server(Guardian.Web.MCP.Server)).frame.private
  end

  for {how, first} <- [
        delete: :query,
        delete: :tools_list,
        delete: :resources_read,
        expire: :query,
      ] do
    test "closing one session (#{how}) leaves #{first} working for another" do
      other = initialize()
      closing = initialize()

      # The closing session is the last one the server process served.
      assert tools_list(closing).status == 200
      close_session(closing, unquote(how))

      case unquote(how) do
        # The bug's precondition: the frame's private map, tools included, is empty.
        :delete -> assert server_frame_private() == %{}
        # Idle expiry never cleared it.
        :expire -> assert [_ | _] = server_frame_private()[:__mcp_components__]
      end

      assert_works_first(unquote(first), other)
      assert_query_tool_works(other)
    end
  end

  defp assert_get_not_allowed(conn) do
    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["POST, DELETE"]
    assert %{"error" => %{"message" => "Method not allowed" <> _}} = Jason.decode!(conn.resp_body)
  end

  defp sse_handler(session_id) do
    transport = Anubis.Server.Registry.transport(Guardian.Web.MCP.Server, :streamable_http)
    Anubis.Server.Transport.StreamableHTTP.get_sse_handler(transport, session_id)
  end

  describe "GET (server-push stream)" do
    # Anubis 0.16 sends request results down a registered GET stream and answers the
    # POST with 202, so a dropped stream loses results. Guardian offers no stream.

    test "a GET without a session gets 405, whatever its Accept header" do
      assert_get_not_allowed(mcp(:get, nil, authed([])))
      assert_get_not_allowed(mcp(:get, nil, authed([]), "text/event-stream"))
      assert_get_not_allowed(mcp(:get, nil, authed([]), "application/json"))
    end

    test "a GET on a live session gets 405, opens no stream, and leaves the session usable" do
      session_id = initialize()

      assert_get_not_allowed(mcp(:get, nil, authed([{"mcp-session-id", session_id}])))
      assert sse_handler(session_id) == nil

      table = "mcp_get_405_#{System.unique_integer([:positive])}"
      Guardian.Engine.ingest_event(table, %{"value" => 1})

      # The result comes back inline in the POST response, not as 202 {}.
      conn =
        mcp(
          :post,
          %{
            jsonrpc: "2.0",
            id: 7,
            method: "tools/call",
            params: %{name: "query", arguments: %{sql: "SELECT value FROM #{table}"}},
          },
          authed([{"mcp-session-id", session_id}])
        )

      assert conn.status == 200
      assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")

      assert %{"id" => 7, "result" => %{"content" => [%{"text" => text}]} = result} =
               Jason.decode!(conn.resp_body)

      refute result["isError"]
      assert Jason.decode!(text) == [%{"value" => 1}]
    end

    test "a GET naming an unknown session still gets 404" do
      assert_session_not_found(mcp(:get, nil, authed([{"mcp-session-id", "bogus-get"}])))
    end

    test "authentication runs before the GET check" do
      assert mcp(:get, nil, []).status == 401
      assert mcp(:get, nil, [{"x-api-key", "wrong"}]).status == 401
    end
  end
end

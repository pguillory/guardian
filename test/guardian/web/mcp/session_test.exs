defmodule Guardian.Web.MCP.SessionTest do
  # The MCP Streamable HTTP spec requires 404 for an unknown session ID, so clients
  # re-initialize after a server restart or session expiry. Sessions are independent, so
  # this module is async.
  use ExUnit.Case, async: true

  @api_key Application.compile_env!(:guardian, :admin_api_key)

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
    session_id
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
    assert_session_not_found(mcp(:post, %{jsonrpc: "2.0", id: 2, method: "tools/list"}, headers))
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

  @stateless_meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{},
  }

  # Newer clients, Anubis 2.x's among them, probe with `server/discover` before
  # `initialize`. Guardian serves only the session era, so it answers "Method not found"
  # and the client falls back to `initialize`.
  test "a session-less server/discover probe gets 200 with Method not found" do
    for id <- [7, "probe-1"] do
      message = %{
        jsonrpc: "2.0",
        id: id,
        method: "server/discover",
        params: %{"_meta" => @stateless_meta},
      }

      conn = mcp(:post, message, authed([]))
      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == []

      assert Jason.decode!(conn.resp_body) == %{
               "jsonrpc" => "2.0",
               "id" => id,
               "error" => %{"code" => -32601, "message" => "Method not found"},
             }
    end
  end

  test "a server/discover naming a session is not answered by the router" do
    message = %{
      jsonrpc: "2.0",
      id: 8,
      method: "server/discover",
      params: %{"_meta" => @stateless_meta},
    }

    assert_session_not_found(mcp(:post, message, authed([{"mcp-session-id", "no-such"}])))

    # On a live session it goes to Anubis, which answers with its own error (the router
    # drops the MCP-Protocol-Version header the stateless era requires).
    session_id = initialize()
    conn = mcp(:post, message, authed([{"mcp-session-id", session_id}]))
    assert %{"id" => 8, "error" => %{"code" => -32020}} = Jason.decode!(conn.resp_body)
  end

  # Validation rejects these before the session check, so they never get -32601.
  test "a server/discover without an id or a stateless _meta is an invalid request" do
    for message <- [
          %{jsonrpc: "2.0", method: "server/discover", params: %{"_meta" => @stateless_meta}},
          %{
            jsonrpc: "2.0",
            id: nil,
            method: "server/discover",
            params: %{"_meta" => @stateless_meta},
          },
          %{jsonrpc: "2.0", id: 1, method: "server/discover", params: %{}},
          %{jsonrpc: "2.0", id: 1, method: "server/discover"},
        ] do
      conn = mcp(:post, message, authed([]))
      assert conn.status == 400
      assert %{"error" => %{"code" => -32600}} = Jason.decode!(conn.resp_body)
    end
  end

  # Anubis 0.16 answered a request without a session ID from a throwaway session
  # ("Server not initialized"), and Anubis 2.x with its own 404 body. Guardian answers
  # every POST other than initialize and server/discover that names no session like an
  # unknown session.
  test "a POST other than initialize without a session ID gets 404" do
    for message <- [
          %{jsonrpc: "2.0", id: 1, method: "tools/list"},
          %{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{"_meta" => @stateless_meta}},
          %{jsonrpc: "2.0", id: 1, method: "ping"},
          %{jsonrpc: "2.0", method: "notifications/initialized"},
          %{jsonrpc: "2.0", id: 1, result: %{}},
        ] do
      conn = mcp(:post, message, authed([]))
      assert conn.status == 404

      assert Jason.decode!(conn.resp_body) == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32001, "message" => "Session not found"},
             }

      assert_session_not_found(mcp(:post, message, authed([{"mcp-session-id", ""}])))
    end
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

  defp close_session(session_id) do
    assert mcp(:delete, nil, authed([{"mcp-session-id", session_id}])).status == 200
    assert_session_not_found(tools_list(session_id))
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

  # Anubis 0.16 kept runtime-registered tools and resources in one frame shared by all
  # sessions and wiped it when a DELETEd session it served last ended, so other live
  # sessions got "Tool not found: query". 2.x gives each session its own frame; these
  # keep the guarantee pinned.
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

  for first <- [:query, :tools_list, :resources_read] do
    test "closing one session leaves #{first} working for another" do
      other = initialize()
      closing = initialize()

      assert tools_list(closing).status == 200
      close_session(closing)

      assert_works_first(unquote(first), other)
      assert_query_tool_works(other)
    end
  end

  defp assert_get_not_allowed(conn) do
    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["POST, DELETE"]
    assert %{"error" => %{"message" => "Method not allowed" <> _}} = Jason.decode!(conn.resp_body)
  end

  describe "GET (server-push stream)" do
    # Anubis 0.16 sent request results down a registered GET stream and answered the
    # POST with 202, so a dropped stream lost results. Guardian offers no stream.

    test "a GET without a session gets 405, whatever its Accept header" do
      assert_get_not_allowed(mcp(:get, nil, authed([])))
      assert_get_not_allowed(mcp(:get, nil, authed([]), "text/event-stream"))
      assert_get_not_allowed(mcp(:get, nil, authed([]), "application/json"))
    end

    test "a GET on a live session gets 405 and leaves the session usable" do
      session_id = initialize()

      assert_get_not_allowed(mcp(:get, nil, authed([{"mcp-session-id", session_id}])))

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

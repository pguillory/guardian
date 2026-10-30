defmodule Guardian.Web.MCP.WireTest do
  # What MCP callers see, pinned where the move from Anubis 0.16 to 2.x would otherwise
  # have changed it (docs/changes/mcp-serialized-tool-calls.md).
  use ExUnit.Case, async: false

  alias Guardian.Test.MCPHTTP

  defp json_body!(conn) do
    assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    Jason.decode!(conn.resp_body)
  end

  defp tools(session_id, headers \\ []) do
    conn =
      MCPHTTP.request(
        :post,
        %{jsonrpc: "2.0", id: 2, method: "tools/list"},
        headers ++ MCPHTTP.session(session_id)
      )

    assert conn.status == 200
    assert %{"result" => %{"tools" => tools}} = json_body!(conn)
    tools
  end

  # A minimal MCP client that sends `accept: application/json, text/event-stream` and
  # parses every body as JSON. Anubis 2.x would answer that Accept with an SSE stream;
  # Guardian answers inline.
  test "a client accepting JSON and SSE gets every answer inline as JSON" do
    init =
      MCPHTTP.request(:post, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-03-26",
          capabilities: %{},
          clientInfo: %{name: "json-reader", version: "1"},
        },
      })

    assert init.status == 200
    assert [session_id] = Plug.Conn.get_resp_header(init, "mcp-session-id")

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "protocolVersion" => "2025-03-26",
               "serverInfo" => %{"name" => "guardian", "version" => "0.1.0"},
               "capabilities" => capabilities,
             },
           } = json_body!(init)

    assert capabilities == %{"tools" => %{}, "resources" => %{}}

    initialized =
      MCPHTTP.request(
        :post,
        %{jsonrpc: "2.0", method: "notifications/initialized"},
        MCPHTTP.session(session_id)
      )

    assert initialized.status == 202

    query = MCPHTTP.call_tool(session_id, 2, "query", %{"sql" => "SELECT 1 AS one"})
    assert MCPHTTP.tool_json!(query, 2) == [%{"one" => 1}]
    assert %{"jsonrpc" => "2.0", "id" => 2, "result" => %{"isError" => false}} = json_body!(query)

    error = MCPHTTP.call_tool(session_id, 3, "query", %{"sql" => "SELEC"})
    assert %{"id" => 3, "result" => %{"isError" => true}} = json_body!(error)

    assert MCPHTTP.request(:delete, nil, MCPHTTP.session(session_id)).status == 200
  end

  test "JSON in any of several Accept headers gets JSON" do
    session_id = MCPHTTP.open_session()

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 5, method: "ping"}))
      |> Map.update!(:req_headers, fn headers ->
        headers ++
          [
            {"content-type", "application/json"},
            {"accept", "text/event-stream"},
            {"accept", "application/json"},
            {"x-api-key", Application.fetch_env!(:guardian, :admin_api_key)},
            {"mcp-session-id", session_id},
          ]
      end)
      |> Guardian.Web.MainRouter.call(nil)

    assert conn.status == 200
    assert %{"id" => 5, "result" => %{}} = json_body!(conn)
  end

  test "tool schemas carry no $schema, and send_events keeps its oneOf options" do
    tools = tools(MCPHTTP.open_session())
    refute Enum.any?(tools, &Map.has_key?(&1["inputSchema"], "$schema"))

    properties =
      Enum.find(tools, &(&1["name"] == "send_events"))["inputSchema"]["properties"]

    assert properties["return_keys"] == %{
             "description" =>
               "Columns to return for successful events, each named in full (user.name), null when missing; for reading decisions and computed values. Omitted or null returns the whole row, [] returns none",
             "oneOf" => [
               %{"type" => "array", "items" => %{"type" => "string"}},
               %{"const" => nil},
             ],
           }

    assert properties["idempotency_key"] == %{
             "description" =>
               "Optional retry key: 1–128 UTF-8 bytes, scoped to this table on this node; reuse only with identical events and return_keys",
             "oneOf" => [%{"type" => "string"}, %{"const" => nil}],
           }
  end

  # Guardian serves one version, so it ignores the header, as Anubis 0.16 did.
  test "the MCP-Protocol-Version header is ignored" do
    session_id = MCPHTTP.open_session()

    for version <- ["2025-03-26", "2025-06-18", "2026-07-28", "not-a-version"] do
      assert [_ | _] = tools(session_id, [{"mcp-protocol-version", version}])
    end
  end

  test "initialize answers 2025-03-26 whatever version the client asks for" do
    for version <- ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"] do
      conn =
        MCPHTTP.request(:post, %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            protocolVersion: version,
            capabilities: %{},
            clientInfo: %{name: "wire-test", version: "0"},
          },
        })

      assert conn.status == 200
      assert %{"result" => %{"protocolVersion" => "2025-03-26"}} = json_body!(conn)
    end
  end
end

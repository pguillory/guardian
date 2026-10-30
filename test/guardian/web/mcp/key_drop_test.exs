defmodule Guardian.Web.MCP.KeyDropTest do
  # Once the API key passes, the router drops it, so Anubis never holds it: not in
  # session state, and not in the request it logs when a call fails.
  use ExUnit.Case, async: false

  alias Guardian.Test.MCPHTTP

  @key Application.compile_env!(:guardian, :admin_api_key)

  test "the router drops the API key before Anubis sees the request" do
    session_id = MCPHTTP.open_session()
    conn = MCPHTTP.call_tool(session_id, 3, "query", %{"sql" => "SELECT 1 AS one"})
    assert MCPHTTP.tool_json!(conn, 3) == [%{"one" => 1}]
    assert Plug.Conn.get_req_header(conn, "x-api-key") == []

    # The session keeps the context of the requests it served: no key in it.
    state = :sys.get_state(MCPHTTP.session_pid(session_id))
    refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ @key
  end

  test "every copy of a repeated API key header is dropped" do
    session_id = MCPHTTP.open_session()

    body = %{
      jsonrpc: "2.0",
      id: 4,
      method: "tools/call",
      params: %{name: "query", arguments: %{sql: "SELECT 1 AS one"}},
    }

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(body))
      |> Map.update!(:req_headers, fn headers ->
        headers ++
          [
            {"content-type", "application/json"},
            {"accept", "application/json"},
            {"x-api-key", @key},
            {"x-api-key", @key},
            {"mcp-session-id", session_id},
          ]
      end)
      |> Guardian.Web.MainRouter.call(nil)

    assert MCPHTTP.tool_json!(conn, 4) == [%{"one" => 1}]
    assert Plug.Conn.get_req_header(conn, "x-api-key") == []

    state = :sys.get_state(MCPHTTP.session_pid(session_id))
    refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ @key
  end
end

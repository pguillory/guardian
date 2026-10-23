defmodule Web.MCP.BodyTest do
  # Not async: capture_log sees every process's log events.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @api_key Application.compile_env!(:guardian, :api_key)
  @marker "PRIVATE_MCP_MARKER_8273"

  defp post(body, headers \\ [{"x-api-key", @api_key}]) do
    conn =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")

    headers
    |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    |> Web.MainRouter.call(nil)
  end

  defp rejected(body) do
    log = capture_log(fn -> send(self(), {:conn, post(body)}) end)
    assert_received {:conn, conn}
    refute log =~ @marker
    {conn.status, Jason.decode!(conn.resp_body), log}
  end

  test "undecodable JSON gets a JSON-RPC parse error and is not logged" do
    body = ~s({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"sql": "#{@marker}")

    assert {400, response, log} = rejected(body)

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32700, "message" => "Parse error"},
           }

    assert log =~ "MCP request body rejected: :invalid_json (#{byte_size(body)} bytes)"
  end

  test "JSON that is not one object gets Invalid Request" do
    body = Jason.encode!([%{jsonrpc: "2.0", id: 1, method: "ping", params: %{x: @marker}}])

    assert {400, %{"error" => %{"code" => -32600}}, log} = rejected(body)
    assert log =~ ":not_an_object"
  end

  test "an invalid message names only a known method" do
    for {method, logged} <- [
          {"tools/call", "method=tools/call"},
          {"#{@marker}\nforged", "method=other"},
        ] do
      body =
        Jason.encode!(%{jsonrpc: "2.0", id: "not-valid-#{@marker}", method: method, params: 5})

      assert {400, %{"error" => %{"code" => -32600}}, log} = rejected(body)
      assert log =~ ":invalid_message"
      assert log =~ logged
      refute log =~ "forged"
    end
  end

  test "params shapes that make Anubis's validation raise are rejected cleanly" do
    for params <- ["#{@marker}", 7, [@marker]] do
      body = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/call", params: params})
      assert {400, %{"error" => %{"code" => -32600}}, _log} = rejected(body)
    end
  end

  test "an empty body gets a parse error" do
    assert {400, %{"error" => %{"code" => -32700}}, _log} = rejected("")
  end

  test "a body over 8 MB gets 413" do
    body =
      ~s({"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {"pad": ") <>
        String.duplicate(@marker, div(9_000_000, byte_size(@marker))) <> ~s("}})

    assert {413, %{"error" => %{"code" => -32600}}, log} = rejected(body)
    assert log =~ ":too_large"
  end

  test "a pretty-printed request is accepted" do
    body =
      Jason.encode!(
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            protocolVersion: "2025-06-18",
            capabilities: %{},
            clientInfo: %{name: "body-test", version: "0"},
          },
        },
        pretty: true
      )

    assert body =~ "\n"
    conn = post(body)
    assert conn.status == 200
    assert [_session_id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")
  end

  # Before the fix the call raised; Bandit (bypassed by Plug.Test) logged the value.
  test "a list- or map-shaped api_key parameter gets 401 instead of crashing" do
    for query <- ["api_key[]=#{@marker}", "api_key[a]=#{@marker}"] do
      log =
        capture_log(fn ->
          conn =
            Plug.Test.conn(:post, "/mcp?" <> query, "{}")
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Web.MainRouter.call(nil)

          send(self(), {:status, conn.status})
        end)

      assert_received {:status, 401}
      refute log =~ @marker
    end
  end

  test "authentication and the session check run before the body is read" do
    assert post("{not json", []).status == 401
    assert post("{not json", [{"x-api-key", "wrong"}]).status == 401

    conn = post("{not json", [{"x-api-key", @api_key}, {"mcp-session-id", "no-such-session"}])
    assert conn.status == 404
  end
end

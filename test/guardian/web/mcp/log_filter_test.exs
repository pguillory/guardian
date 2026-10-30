defmodule Guardian.Web.MCP.LogFilterTest do
  # Anubis logs a timed-out or failed call's exit reason, which holds the whole MCP
  # request. Guardian.Web.MCP.LogFilter keeps the request out of that line, and the
  # router keeps the API key out of Anubis altogether.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Anubis.Logging
  require Logger

  alias Anubis.Server.Transport.Session.Local
  alias Guardian.Test.MCPHTTP

  @key Application.compile_env!(:guardian, :admin_api_key)
  @sql "SELECT 'needle-in-the-body' AS secret"

  defp call(sql) do
    %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"name" => "query", "arguments" => %{"sql" => sql}},
    }
  end

  # What Anubis's Streamable HTTP plug does when the session call exits: makes the
  # real call, catches the exit and logs its reason.
  defp log_call_failure(session, timeout \\ 50) do
    context = %{type: :http, req_headers: [{"x-api-key", @key}, {"user-agent", "test"}]}
    reason = catch_exit(Local.dispatch_request(session, call(@sql), context, timeout: timeout))
    log_failure(reason)
  end

  defp log_failure(reason) do
    capture_log([level: :error], fn ->
      Anubis.Logging.transport_event("session_call_failed", %{reason: reason}, level: :error)
    end)
  end

  defp assert_redacted(log, kind) do
    assert log =~ "MCP transport event: session_call_failed"
    assert log =~ "MCP transport details: MCP call exited (#{kind}); request redacted"
    refute log =~ @key
    refute log =~ "needle-in-the-body"
    refute log =~ "x-api-key"
  end

  test "a timed-out call's log line names the exit reason, not the request" do
    silent = spawn_link(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(silent, :kill) end)
    assert_redacted(log_call_failure(silent), "timeout")
  end

  test "a call to a dead session's log line names the exit reason, not the request" do
    {dead, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    assert_redacted(log_call_failure(dead), "noproc")
  end

  test "an exit reason that is not a plain atom is still redacted" do
    # Request text that looks like a reason must not be picked up as one.
    message = call("SELECT '%{reason: {:looks_like_a_reason, 1}}' AS needle-in-the-body")
    call = {:mcp_request, message, %{req_headers: [{"x-api-key", @key}]}}
    reason = {{:shutdown, :closed}, {GenServer, :call, [self(), call, 30_000]}}
    log = log_failure(reason)
    assert_redacted(log, "unknown")
    refute log =~ "looks_like_a_reason"
  end

  test "other Anubis lines and other loggers pass unchanged" do
    log =
      capture_log([level: :error], fn ->
        Anubis.Logging.transport_event("other_event", %{reason: :closed}, level: :error)
        Logger.error("unrelated {:mcp_request, kept}")
      end)

    assert log =~ "MCP transport details: %{reason: :closed}"
    assert log =~ "unrelated {:mcp_request, kept}"
  end

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

defmodule Guardian.Web.QueryLogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Guardian.Web.QueryLog

  @api_key Application.compile_env!(:guardian, :api_key)

  defp marker, do: "marker_#{System.unique_integer([:positive])}"

  defp rows_for(sql, server \\ QueryLog) do
    :ok = QueryLog.sync(server)

    QueryLog.table()
    |> Guardian.Storage.dump_table()
    |> Enum.filter(&(&1["sql"] == sql))
  end

  defp http_query(sql, headers \\ []) do
    conn =
      Plug.Test.conn(:post, "https://localhost/api/json/query", Jason.encode!(%{query: sql}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", @api_key)

    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)

    try do
      conn = Guardian.Web.MainRouter.call(conn, nil)
      {conn.status, Jason.decode!(conn.resp_body)}
    rescue
      # Plug.ErrorHandler sends the 500 response and then reraises the error.
      e in Plug.Conn.WrapperError ->
        assert_received {_ref, {status, _headers, body}}
        {status, Jason.decode!(body), e.reason}
    end
  end

  defp mcp_query(sql) do
    Guardian.MCPTestClient.start()
    {:ok, response} = Guardian.MCPTestClient.call_tool("query", %{"sql" => sql})
    response.result
  end

  defp info(caller \\ %{"interface" => "http"}) do
    %{timestamp: Guardian.Timestamp.now(), duration_native: 0, caller_fun: fn -> caller end}
  end

  describe "JSON API" do
    test "a successful query records one row, without the key or headers" do
      table = marker()
      Guardian.Engine.ingest_events(table, [%{"v" => 1}, %{"v" => 2}])
      sql = "SELECT v FROM #{table}"

      assert {200, %{"rows" => [[1], [2]]}} =
               http_query(sql, [{"user-agent", "secret-agent"}, {"x-forwarded-for", "9.9.9.9"}])

      assert [row] = rows_for(sql)
      assert row["interface"] == "http"
      assert row["outcome"] == "ok"
      assert row["row_count"] == 2
      assert row["error_kind"] == nil
      assert row["error"] == nil
      assert row["remote_ip"] == "127.0.0.1"
      assert is_float(row["duration_ms"]) and row["duration_ms"] >= 0
      assert row["sql_bytes"] == byte_size(sql)
      assert row["sql_truncated"] == false
      assert row["dropped_before"] == 0
      assert row["hostname"] == Guardian.Utils.hostname()
      assert row["timestamp"] =~ ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/

      values = row |> Map.values() |> Enum.map(&inspect/1) |> Enum.join(" ")
      refute values =~ @api_key
      refute values =~ "secret-agent"
      refute values =~ "9.9.9.9"
      refute Map.has_key?(row, "user_agent")
      refute Map.has_key?(row, "x_forwarded_for")
    end

    test "a query error (400) records outcome error, kind query" do
      sql = "SELECT max_n(1, -1) AS #{marker()}"
      assert {400, %{"info" => info}} = http_query(sql)

      assert [row] = rows_for(sql)
      assert row["outcome"] == "error"
      assert row["error_kind"] == "query"
      assert row["error"] == info
      assert row["row_count"] == nil
    end

    test "a statement-count rejection records kind query" do
      sql = "SELECT 1 FROM #{marker()}; SELECT 2"
      assert {400, _} = http_query(sql)
      assert [%{"error_kind" => "query", "outcome" => "error"}] = rows_for(sql)
    end

    test "a parse error returns the same 500 and records kind parse" do
      sql = "SELECT FROM #{marker()} WHERE"
      assert {500, %{"status" => 500}, %Guardian.AST.ParseError{} = error} = http_query(sql)

      assert [row] = rows_for(sql)
      assert row["error_kind"] == "parse"
      assert row["error"] == Exception.message(error)
    end

    test "an internal error (500) records kind internal with the unsent message" do
      table = marker()
      Guardian.Engine.ingest_event(table, %{"a" => 1, "A" => 2})
      sql = "SELECT a FROM #{table}"

      assert {500, %{"status" => 500}, error} = http_query(sql)
      assert [row] = rows_for(sql)
      assert row["error_kind"] == "internal"
      assert row["error"] == Exception.message(error)
      assert row["error"] =~ "ambiguous column"
    end

    test "a stalled recorder does not delay the response; the row lands when it resumes" do
      sql = "SELECT 1 FROM #{marker()}"
      pid = Process.whereis(QueryLog)
      :ok = :sys.suspend(pid)

      try do
        {micros, result} = :timer.tc(fn -> http_query(sql) end)
        assert {200, _} = result
        assert micros < 1_000_000
      after
        :ok = :sys.resume(pid)
      end

      assert [_row] = rows_for(sql)
    end

    test "a stopped recorder is logged and the query still succeeds" do
      sql = "SELECT 1 FROM #{marker()}"
      :ok = Supervisor.terminate_child(Guardian.Main, QueryLog)

      try do
        log = capture_log(fn -> assert {200, _} = http_query(sql) end)
        assert log =~ "Failed to record a query in queries: the recorder is not running"
        refute log =~ sql
      after
        {:ok, _} = Supervisor.restart_child(Guardian.Main, QueryLog)
      end

      assert rows_for(sql) == []
    end

    test "a query on the queries table logs exactly one row" do
      sql = "SELECT count() FROM queries WHERE sql = '#{marker()}'"
      assert {200, _} = http_query(sql)
      assert {200, _} = http_query(sql)
      assert [_, _] = rows_for(sql)
    end

    test "the table is queryable" do
      sql = "SELECT 1 FROM #{marker()}"
      http_query(sql)
      :ok = QueryLog.sync()

      assert {200, %{"rows" => keys}} = http_query("DESC queries")

      for key <-
            ~w(timestamp hostname interface remote_ip sql sql_bytes sql_truncated duration_ms outcome row_count error_kind error dropped_before) do
        assert [key] in keys
      end
    end
  end

  describe "MCP" do
    test "a successful query records one row with the client's name" do
      table = marker()
      Guardian.Engine.ingest_events(table, [%{"v" => 1}])
      sql = "SELECT v FROM #{table}"
      assert %{"isError" => false} = mcp_query(sql)

      assert [row] = rows_for(sql)
      assert row["interface"] == "mcp"
      assert row["outcome"] == "ok"
      assert row["row_count"] == 1
      assert row["mcp_client_name"] == "guardian"
      assert row["mcp_client_version"] == "0.1.0"
      refute Map.has_key?(row, "user_agent")
      refute row |> Map.values() |> Enum.map(&inspect/1) |> Enum.join(" ") =~ @api_key
    end

    test "a query error records kind query with the tool error's text" do
      sql = "SELECT max_n(1, -1) AS #{marker()}"
      assert %{"isError" => true, "content" => [%{"text" => text}]} = mcp_query(sql)
      assert [%{"error_kind" => "query", "error" => ^text}] = rows_for(sql)
    end

    test "an internal error (ambiguous column) records kind internal with its message" do
      table = marker()
      Guardian.Engine.ingest_event(table, %{"a" => 1, "A" => 2})
      sql = "SELECT a FROM #{table}"

      assert %{"isError" => true, "content" => [%{"text" => text}]} = mcp_query(sql)
      assert [row] = rows_for(sql)
      assert row["error_kind"] == "internal"
      assert row["error"] == text
    end

    test "a parse error records kind parse with the tool error's text" do
      sql = "SELECT FROM #{marker()} WHERE"
      assert %{"isError" => true, "content" => [%{"text" => text}]} = mcp_query(sql)
      assert [%{"error_kind" => "parse", "error" => ^text}] = rows_for(sql)
    end
  end

  describe "Guardian.Web.Query.execute/3" do
    setup do
      server = :"query_log_test_#{System.unique_integer([:positive])}"
      start_supervised!({QueryLog, name: server})
      %{server: server}
    end

    test "a caller function that fails loses the row, not the query's outcome",
         %{server: server} do
      sql = "SELECT FROM #{marker()} WHERE"
      opts = [query_log: server, server: :no_such_parse_error_recorder]

      log =
        capture_log(fn ->
          assert_raise Guardian.AST.ParseError, fn ->
            Guardian.Web.Query.execute(sql, fn -> exit(:caller_gone) end, opts)
          end
        end)

      assert log =~ "Failed to record a query in queries: exit :caller_gone"
      assert rows_for(sql, server) == []
    end

    test "exits and throws from the query path are reraised unchanged and recorded by kind",
         %{server: server} do
      failures = [
        {:exit, {:timeout, {GenServer, :call, ["secret"]}}, "exit :timeout"},
        {:throw, {:secret, 1}, "throw"},
        {:error, :badarg, "argument error"},
      ]

      stacktrace = [{SomeModule, :some_function, 2, [file: ~c"sentinel.ex", line: 7]}]

      for {kind, reason, error} <- failures do
        sql = "SELECT 1 FROM #{marker()}"
        execute = fn _sql, _opts -> :erlang.raise(kind, reason, stacktrace) end
        opts = [query_log: server, execute: execute]

        assert {^kind, ^reason, ^stacktrace} =
                 (try do
                    Guardian.Web.Query.execute(sql, fn -> %{"interface" => "http"} end, opts)
                  catch
                    caught_kind, caught_reason -> {caught_kind, caught_reason, __STACKTRACE__}
                  end)

        assert [row] = rows_for(sql, server)
        assert row["outcome"] == "error"
        assert row["error_kind"] == "internal"
        assert row["error"] == error
      end
    end
  end

  describe "rows" do
    test "long SQL and errors are cut on a UTF-8 boundary" do
      sql = "SELECT " <> String.duplicate("é", 10_000)
      message = "x" <> String.duplicate("é", 1000)
      row = QueryLog.row(sql, {:error, "query", message}, info())

      assert row["sql_truncated"] == true
      assert row["sql_bytes"] == byte_size(sql)
      assert String.valid?(row["sql"])
      assert byte_size(row["sql"]) in (QueryLog.max_sql_bytes() - 1)..QueryLog.max_sql_bytes()
      assert String.starts_with?(sql, row["sql"])
      assert String.valid?(row["error"])

      assert byte_size(row["error"]) in (QueryLog.max_error_bytes() - 1)..QueryLog.max_error_bytes()
    end

    test "only interface, remote_ip and the MCP client fields are kept from the caller" do
      caller = %{
        "interface" => "mcp",
        "remote_ip" => "1.2.3.4",
        "user_agent" => "ua",
        "x_forwarded_for" => "5.6.7.8",
        "mcp_client_name" => String.duplicate("x", 10_000),
        "mcp_client_version" => %{"nested" => 1},
      }

      row = QueryLog.row("SELECT 1", {:ok, 1}, info(caller))
      assert row["remote_ip"] == "1.2.3.4"
      assert byte_size(row["mcp_client_name"]) == 256
      assert row["mcp_client_version"] == nil
      refute Map.has_key?(row, "user_agent")
      refute Map.has_key?(row, "x_forwarded_for")
    end

    test "duration_ms is fractional milliseconds" do
      duration = System.convert_time_unit(1500, :microsecond, :native)
      row = QueryLog.row("SELECT 1", {:ok, 1}, %{info() | duration_native: duration})
      assert row["duration_ms"] == 1.5
    end
  end

  describe "recorder" do
    test "a failed write is logged by kind and counted in the next row's dropped_before" do
      failures = :counters.new(1, [])
      :counters.put(failures, 1, 1)
      test_pid = self()

      writer = fn table, row ->
        if :counters.get(failures, 1) > 0 do
          :counters.sub(failures, 1, 1)
          {:error, "RuntimeError"}
        else
          send(test_pid, {:written, table, row})
          {:ok, row}
        end
      end

      server = :"query_log_test_#{System.unique_integer([:positive])}"
      start_supervised!({QueryLog, name: server, writer: writer})

      log =
        capture_log(fn ->
          :ok = QueryLog.record("SELECT secret", {:ok, 0}, info(), server: server)
          :ok = QueryLog.sync(server)
        end)

      assert log =~ "Failed to record a query in queries: RuntimeError"
      refute log =~ "secret"

      :ok = QueryLog.record("SELECT 2", {:ok, 0}, info(), server: server)
      :ok = QueryLog.sync(server)
      assert_received {:written, "queries", %{"sql" => "SELECT 2", "dropped_before" => 1}}
    end

    test "a full backlog drops rows, logs once, and counts them" do
      test_pid = self()

      writer = fn _table, row ->
        send(test_pid, {:written, row})
        {:ok, row}
      end

      server = :"query_log_test_#{System.unique_integer([:positive])}"
      pid = start_supervised!({QueryLog, name: server, writer: writer})
      :ok = :sys.suspend(pid)

      log =
        capture_log(fn ->
          try do
            for i <- 1..1003 do
              :ok = QueryLog.record("SELECT #{i}", {:ok, 0}, info(), server: server)
            end
          after
            :ok = :sys.resume(pid)
          end

          :ok = QueryLog.sync(server)
        end)

      assert length(String.split(log, "rows behind")) == 2

      :ok = QueryLog.record("SELECT last", {:ok, 0}, info(), server: server)
      :ok = QueryLog.sync(server)

      written =
        for _ <- 1..1001 do
          assert_receive {:written, row}
          row
        end

      dropped = written |> Enum.map(& &1["dropped_before"]) |> Enum.sum()
      assert dropped == 3

      # The backlog drained, so a new one logs again.
      :ok = :sys.suspend(pid)

      log =
        capture_log(fn ->
          try do
            for i <- 1..1001 do
              :ok = QueryLog.record("SELECT again #{i}", {:ok, 0}, info(), server: server)
            end
          after
            :ok = :sys.resume(pid)
          end

          :ok = QueryLog.sync(server)
        end)

      assert length(String.split(log, "rows behind")) == 2
    end

    test "record never raises, even when the row cannot be built" do
      log =
        capture_log(fn ->
          bad = %{timestamp: nil, duration_native: :oops, caller_fun: fn -> raise "secret" end}
          assert QueryLog.record("SELECT secret", {:ok, 0}, bad) == :ok
        end)

      assert log =~ "Failed to record a query in queries:"
      refute log =~ "secret"
    end
  end
end

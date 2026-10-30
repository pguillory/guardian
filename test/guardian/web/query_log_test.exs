defmodule Guardian.Web.QueryLogTest do
  use ExUnit.Case, async: false
  import Guardian.Web.QueryLog

  import ExUnit.CaptureLog
  import Guardian.Test.Segments, only: [hand_off_mutable_segments: 1, intercept_append: 2]

  alias Guardian.Web.QueryLog

  @api_key Application.compile_env!(:guardian, :admin_api_key)

  defp marker do
    "marker_#{System.unique_integer([:positive])}"
  end

  defp rows_for(sql, server \\ QueryLog) do
    :ok = sync(server)

    table()
    |> Guardian.Storage.dump_table()
    |> Enum.filter(&(&1["sql"] == sql))
  end

  defp mcp_query(sql) do
    Guardian.Test.MCPClient.start()
    {:ok, response} = Guardian.Test.MCPClient.call_tool("query", %{"sql" => sql})
    response.result
  end

  # A caller as the MCP query tool builds it (QueryParseErrors.mcp_caller/1), with the
  # headers that must not be recorded.
  @caller %{
    "interface" => "mcp",
    "remote_ip" => "127.0.0.1",
    "x_forwarded_for" => "9.9.9.9",
    "user_agent" => "secret-agent",
    "mcp_client_name" => "client",
    "mcp_client_version" => "1.0",
  }

  # Runs a query the way the MCP tool does, through Guardian.Web.Query.execute/3; a
  # raise comes back as {:raised, exception}.
  defp run(sql) do
    Guardian.Web.Query.execute(sql, fn -> @caller end)
  rescue
    error -> {:raised, error}
  end

  defp info(caller \\ %{"interface" => "mcp"}) do
    %{timestamp: Guardian.Timestamp.now(), duration_native: 0, caller_fun: fn -> caller end}
  end

  describe "recording through Guardian.Web.Query" do
    test "a successful query records one row, without headers" do
      table = marker()
      Guardian.Engine.ingest_events(table, [%{"v" => 1}, %{"v" => 2}])
      sql = "SELECT v FROM #{table}"

      assert {:ok, _labels, [[1], [2]]} = run(sql)

      assert [row] = rows_for(sql)
      assert row["interface"] == "mcp"
      assert row["outcome"] == "ok"
      assert row["row_count"] == 2
      assert row["error_kind"] == nil
      assert row["error"] == nil
      assert row["remote_ip"] == "127.0.0.1"
      assert row["mcp_client_name"] == "client"
      assert is_float(row["duration_ms"]) and row["duration_ms"] >= 0
      assert row["sql_bytes"] == byte_size(sql)
      assert row["sql_truncated"] == false
      assert row["dropped_before"] == 0
      assert row["hostname"] == Guardian.Utils.hostname()
      assert row["timestamp"] =~ ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/

      values = row |> Map.values() |> Enum.map(&inspect/1) |> Enum.join(" ")
      refute values =~ "secret-agent"
      refute values =~ "9.9.9.9"
      refute Map.has_key?(row, "user_agent")
      refute Map.has_key?(row, "x_forwarded_for")
    end

    test "a query error records outcome error, kind query" do
      sql = "SELECT max_n(1, -1) AS #{marker()}"
      assert {:error, info} = run(sql)

      assert [row] = rows_for(sql)
      assert row["outcome"] == "error"
      assert row["error_kind"] == "query"
      assert row["error"] == info
      assert row["row_count"] == nil
    end

    test "a statement-count rejection records kind query" do
      sql = "SELECT 1 FROM #{marker()}; SELECT 2"
      assert {:error, _} = run(sql)
      assert [%{"error_kind" => "query", "outcome" => "error"}] = rows_for(sql)
    end

    test "a SELECT * without a table records kind query" do
      sql = "LET #{marker()} = 1; SELECT *"
      assert {:error, "SELECT * needs FROM and a table name"} = run(sql)
      assert [%{"error_kind" => "query", "outcome" => "error"}] = rows_for(sql)
    end

    test "a parse error is reraised unchanged and records kind parse" do
      sql = "SELECT FROM #{marker()} WHERE"
      assert {:raised, %Guardian.AST.ParseError{} = error} = run(sql)

      assert [row] = rows_for(sql)
      assert row["error_kind"] == "parse"
      assert row["error"] == Exception.message(error)
    end

    test "a LET function given the wrong number of arguments records kind query" do
      sql = "LET coalesce(a) = a; SELECT coalesce(1, 2) AS #{marker()}"
      assert {:error, "Wrong number of arguments" <> _} = run(sql)
      assert [%{"error_kind" => "query", "outcome" => "error"}] = rows_for(sql)
    end

    test "an internal error is reraised unchanged and records kind internal with its message" do
      sql = "SELECT 1 AS #{marker()}"
      error = %RuntimeError{message: "internal failure"}
      Guardian.Test.Web.QueryBackend.fail_next(:error, error, [])

      assert {:raised, ^error} = run(sql)

      assert [row] = rows_for(sql)
      assert row["error_kind"] == "internal"
      assert row["error"] == "internal failure"
    end

    test "a stalled recorder does not delay the result; the row lands when it resumes" do
      sql = "SELECT 1 FROM #{marker()}"
      pid = Process.whereis(QueryLog)
      :ok = :sys.suspend(pid)

      try do
        {micros, result} = :timer.tc(fn -> run(sql) end)
        assert {:ok, _, _} = result
        assert micros < 1_000_000
      after
        :ok = :sys.resume(pid)
      end

      assert [_row] = rows_for(sql)
    end

    test "a query on the queries table logs exactly one row" do
      sql = "SELECT count() FROM queries WHERE sql = '#{marker()}'"
      assert {:ok, _, _} = run(sql)
      assert {:ok, _, _} = run(sql)
      assert [_, _] = rows_for(sql)
    end

    test "the table is queryable" do
      sql = "SELECT 1 FROM #{marker()}"
      run(sql)
      :ok = sync()

      assert {:ok, _, keys} = run("DESC queries")

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

    test "a resolve-time query error records kind query with the tool error's text" do
      sql = "LET coalesce(a) = a; SELECT coalesce(1, 2) AS #{marker()}"
      assert %{"isError" => true, "content" => [%{"text" => text}]} = mcp_query(sql)
      assert text =~ "Wrong number of arguments"
      assert [%{"error_kind" => "query", "error" => ^text}] = rows_for(sql)
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
        opts = [query_log: server]
        Guardian.Test.Web.QueryBackend.fail_next(kind, reason, stacktrace)

        assert {^kind, ^reason, ^stacktrace} =
                 (try do
                    Guardian.Web.Query.execute(sql, fn -> %{"interface" => "mcp"} end, opts)
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
      row = row(sql, {:error, "query", message}, info())

      assert row["sql_truncated"] == true
      assert row["sql_bytes"] == byte_size(sql)
      assert String.valid?(row["sql"])
      assert byte_size(row["sql"]) in (max_sql_bytes() - 1)..max_sql_bytes()
      assert String.starts_with?(sql, row["sql"])
      assert String.valid?(row["error"])

      assert byte_size(row["error"]) in (max_error_bytes() - 1)..max_error_bytes()
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

      row = row("SELECT 1", {:ok, 1}, info(caller))
      assert row["remote_ip"] == "1.2.3.4"
      assert byte_size(row["mcp_client_name"]) == 256
      assert row["mcp_client_version"] == nil
      refute Map.has_key?(row, "user_agent")
      refute Map.has_key?(row, "x_forwarded_for")
    end

    test "duration_ms is fractional milliseconds" do
      duration = System.convert_time_unit(1500, :microsecond, :native)
      row = row("SELECT 1", {:ok, 1}, %{info() | duration_native: duration})
      assert row["duration_ms"] == 1.5
    end
  end

  describe "recorder" do
    test "a failed write is logged by kind and counted in the next row's dropped_before" do
      server = :"query_log_test_#{System.unique_integer([:positive])}"
      start_supervised!({QueryLog, name: server})

      # The default recorder must have finished, so the refused row is this test's.
      :ok = sync()
      hand_off_mutable_segments(table())

      intercept_append(table(), fn from, _row ->
        GenServer.reply(from, {:error, :invalid_value})
      end)

      [lost, kept] = ["SELECT secret #{marker()}", "SELECT #{marker()}"]

      log =
        capture_log(fn ->
          :ok = record(lost, {:ok, 0}, info(), server: server)
          :ok = sync(server)
        end)

      assert log =~ "Failed to record a query in queries: ArgumentError"
      refute log =~ "secret"

      :ok = record(kept, {:ok, 0}, info(), server: server)
      assert rows_for(lost, server) == []
      assert [%{"dropped_before" => 1}] = rows_for(kept, server)
    end

    test "a full backlog drops rows, logs once, and counts them" do
      server = :"query_log_test_#{System.unique_integer([:positive])}"
      pid = start_supervised!({QueryLog, name: server})
      prefix = "SELECT #{marker()} "
      :ok = :sys.suspend(pid)

      log =
        capture_log(fn ->
          try do
            for i <- 1..1003 do
              :ok = record("#{prefix}#{i}", {:ok, 0}, info(), server: server)
            end
          after
            :ok = :sys.resume(pid)
          end

          :ok = sync(server)
        end)

      assert length(String.split(log, "rows behind")) == 2

      :ok = record("#{prefix}last", {:ok, 0}, info(), server: server)
      :ok = sync(server)

      written =
        table()
        |> Guardian.Storage.dump_table()
        # Not every row has `sql`: other tests write to this table directly.
        |> Enum.filter(&(is_binary(&1["sql"]) and String.starts_with?(&1["sql"], prefix)))

      assert length(written) == 1001
      dropped = written |> Enum.map(& &1["dropped_before"]) |> Enum.sum()
      assert dropped == 3

      # The backlog drained, so a new one logs again.
      :ok = :sys.suspend(pid)

      log =
        capture_log(fn ->
          try do
            for i <- 1..1001 do
              :ok = record("SELECT again #{i}", {:ok, 0}, info(), server: server)
            end
          after
            :ok = :sys.resume(pid)
          end

          :ok = sync(server)
        end)

      assert length(String.split(log, "rows behind")) == 2
    end

    test "record never raises, even when the row cannot be built" do
      log =
        capture_log(fn ->
          bad = %{timestamp: nil, duration_native: :oops, caller_fun: fn -> raise "secret" end}
          assert record("SELECT secret", {:ok, 0}, bad) == :ok
        end)

      assert log =~ "Failed to record a query in queries:"
      refute log =~ "secret"
    end
  end
end

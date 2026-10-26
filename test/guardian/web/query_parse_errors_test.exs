defmodule Guardian.Web.QueryParseErrorsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Guardian.Test.JsonApiClient
  alias Guardian.Web.QueryParseErrors

  # Malformed SQL unique to one test, so rows can be told apart in the shared table.
  defp bad_sql do
    "SELECT FROM marker_#{System.unique_integer([:positive])} WHERE"
  end

  defp rows_for(sql, server \\ QueryParseErrors) do
    :ok = QueryParseErrors.sync(server)

    QueryParseErrors.table()
    |> Guardian.Storage.dump_table()
    |> Enum.filter(&(&1["sql"] == sql))
  end

  defp parse_message(sql) do
    try do
      Guardian.Query.Resolver.resolve(sql)
      flunk("expected a parse error for #{inspect(sql)}")
    rescue
      e in Guardian.AST.ParseError -> Exception.message(e)
    end
  end

  describe "JSON API" do
    test "a parse error returns the same 500 and records one row" do
      sql = bad_sql()

      assert {500, %{"status" => 500}} =
               JsonApiClient.query(sql, [
                 {"user-agent", "test-agent/1"},
                 {"x-forwarded-for", "9.9.9.9"},
               ])

      assert [row] = rows_for(sql)
      assert row["interface"] == "http"
      assert row["error"] == parse_message(sql)
      assert row["error"] =~ "Parse error on line 1"
      assert row["user_agent"] == "test-agent/1"
      assert row["x_forwarded_for"] == "9.9.9.9"
      assert row["remote_ip"] == "127.0.0.1"
      assert row["sql_bytes"] == byte_size(sql)
      assert row["sql_truncated"] == false
      assert row["dropped_before"] == 0
      assert row["hostname"] == Guardian.Utils.hostname()
      assert row["timestamp"] =~ ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/
      refute Map.has_key?(row, "mcp_client_name")
    end

    test "valid queries and statement-count rejections record nothing" do
      marker = "valid_#{System.unique_integer([:positive])}_end"

      assert {200, _} = JsonApiClient.query("SELECT 1 FROM #{marker}")
      assert {400, _} = JsonApiClient.query("SELECT 1 FROM #{marker}; SELECT 2")
      :ok = QueryParseErrors.sync()

      rows = Guardian.Storage.dump_table(QueryParseErrors.table())
      refute Enum.any?(rows, &String.contains?(&1["sql"] || "", marker))
    end

    test "a stopped recorder is logged and the caller still gets the parse error 500" do
      sql = bad_sql()
      :ok = Supervisor.terminate_child(Guardian.Application, QueryParseErrors)

      try do
        log =
          capture_log(fn ->
            assert {500, %{"status" => 500}} = JsonApiClient.query(sql)
          end)

        assert log =~ "Failed to record a http query parse error: the recorder is not running"
      after
        {:ok, _} = Supervisor.restart_child(Guardian.Application, QueryParseErrors)
      end

      assert rows_for(sql) == []
    end

    test "a stalled recorder does not delay the response; the row lands when it resumes" do
      sql = bad_sql()
      pid = Process.whereis(QueryParseErrors)
      :ok = :sys.suspend(pid)

      try do
        {micros, result} = :timer.tc(fn -> JsonApiClient.query(sql) end)
        assert {500, %{"status" => 500}} = result
        assert micros < 1_000_000
      after
        :ok = :sys.resume(pid)
      end

      assert [_row] = rows_for(sql)
    end

    test "the table is queryable like other built-in tables" do
      sql = bad_sql()
      JsonApiClient.query(sql)
      :ok = QueryParseErrors.sync()

      assert {200, %{"rows" => tables}} = JsonApiClient.query("SHOW TABLES")
      assert ["query_parse_errors"] in tables

      assert {200, %{"rows" => keys}} = JsonApiClient.query("DESC query_parse_errors")

      for key <-
            ~w(timestamp hostname interface remote_ip sql sql_bytes sql_truncated error dropped_before) do
        assert [key] in keys
      end

      assert {200, %{"rows" => [["http", ^sql]]}} =
               JsonApiClient.query(
                 "SELECT interface, sql FROM query_parse_errors WHERE sql = '#{sql}'"
               )
    end

    test "a failure while building the row is logged by kind only and returns :ok" do
      error = %Guardian.AST.ParseError{reason: "test", row: 0, col: 0}

      callers = [
        {fn -> raise "boom secret" end, "RuntimeError"},
        {fn -> exit({:boom, "secret"}) end, "exit :boom"},
        {fn -> throw({:boom, "secret"}) end, "throw"},
      ]

      for {caller_fun, kind} <- callers do
        log =
          capture_log(fn ->
            assert QueryParseErrors.record(bad_sql(), error, caller_fun) == :ok
          end)

        assert log =~ "Failed to record a query parse error: #{kind}"
        refute log =~ "secret"
      end
    end
  end

  describe "MCP" do
    test "a parse error returns the same tool error and records one row" do
      sql = bad_sql()
      Guardian.Test.MCPClient.start()

      {:ok, response} = Guardian.Test.MCPClient.call_tool("query", %{"sql" => sql})

      assert response.result["isError"] == true
      assert [%{"text" => text}] = response.result["content"]
      assert text == parse_message(sql)

      assert [row] = rows_for(sql)
      assert row["interface"] == "mcp"
      assert row["error"] == text
      assert row["mcp_client_name"] == "guardian"
      assert row["mcp_client_version"] == "0.1.0"
      assert row["remote_ip"] == "127.0.0.1"
      assert row["sql_bytes"] == byte_size(sql)
    end

    test "resolve errors are not recorded" do
      table = "ambiguous_#{System.unique_integer([:positive])}_end"
      Guardian.Engine.ingest_event(table, %{"a" => 1, "A" => 2})
      Guardian.Test.MCPClient.start()

      {:ok, response} =
        Guardian.Test.MCPClient.call_tool("query", %{"sql" => "SELECT a FROM #{table}"})

      assert response.result["isError"] == true
      assert [%{"text" => "ambiguous column" <> _}] = response.result["content"]
      :ok = QueryParseErrors.sync()

      refute Enum.any?(
               Guardian.Storage.dump_table(QueryParseErrors.table()),
               &String.contains?(&1["sql"] || "", table)
             )
    end

    test "an unknown function is a parse error and is recorded" do
      sql = "SELECT no_such_function_#{System.unique_integer([:positive])}(1)"
      Guardian.Test.MCPClient.start()

      {:ok, response} =
        Guardian.Test.MCPClient.call_tool("query", %{"sql" => sql})

      assert [%{"text" => "Parse error" <> _ = text}] = response.result["content"]
      assert [%{"error" => ^text}] = rows_for(sql)
    end
  end

  describe "bounds" do
    test "long SQL is cut to 16 KiB on a UTF-8 boundary" do
      # "é" is two bytes after an odd-length prefix, so the cap splits a character.
      sql = "SELECT FROM x WHERE " <> String.duplicate("é", 10_000)
      error = %Guardian.AST.ParseError{reason: "test", row: 0, col: 0}
      row = QueryParseErrors.row(sql, error, %{"interface" => "http"})

      assert row["sql_truncated"] == true
      assert row["sql_bytes"] == byte_size(sql)
      assert String.valid?(row["sql"])

      assert byte_size(row["sql"]) in (QueryParseErrors.max_sql_bytes() - 1)..QueryParseErrors.max_sql_bytes()

      assert String.starts_with?(sql, row["sql"])
    end

    test "caller fields are capped and non-strings become null" do
      error = %Guardian.AST.ParseError{reason: "test", row: 0, col: 0}
      long = String.duplicate("x", 10_000)

      row =
        QueryParseErrors.row("SELECT", error, %{
          "interface" => "mcp",
          "mcp_client_name" => long,
          "mcp_client_version" => %{"nested" => 1},
        })

      assert byte_size(row["mcp_client_name"]) == QueryParseErrors.max_caller_field_bytes()
      assert row["mcp_client_version"] == nil
    end

    test "a failed write is logged and its row joins dropped_before" do
      failures = :counters.new(1, [])
      :counters.put(failures, 1, 1)
      server = :"writer_#{System.unique_integer([:positive])}"

      writer = fn table, row ->
        if :counters.get(failures, 1) > 0 do
          :counters.sub(failures, 1, 1)
          # What Guardian.Engine.try_log_event/2 returns for a raised RuntimeError.
          {:error, "RuntimeError"}
        else
          Guardian.Engine.try_log_event(table, row)
        end
      end

      start_supervised!({QueryParseErrors, name: server, writer: writer})
      error = %Guardian.AST.ParseError{reason: "test", row: 0, col: 0}
      [lost, kept] = [bad_sql(), bad_sql()]

      log =
        capture_log(fn ->
          :ok =
            QueryParseErrors.record(lost, error, fn -> %{"interface" => "http"} end,
              server: server
            )

          :ok = QueryParseErrors.sync(server)
        end)

      assert log =~ "Failed to record a http query parse error: RuntimeError"

      :ok =
        QueryParseErrors.record(kept, error, fn -> %{"interface" => "http"} end, server: server)

      assert rows_for(lost, server) == []
      assert [%{"dropped_before" => 1}] = rows_for(kept, server)
    end

    test "a backlogged recorder drops new rows with a log instead of queueing them" do
      server = :"backlog_#{System.unique_integer([:positive])}"
      pid = start_supervised!({QueryParseErrors, name: server})
      :ok = :sys.suspend(pid)
      error = %Guardian.AST.ParseError{reason: "test", row: 0, col: 0}
      for _ <- 1..100, do: GenServer.cast(pid, :filler)
      sql = bad_sql()

      log =
        capture_log(fn ->
          :ok =
            QueryParseErrors.record(sql, error, fn -> %{"interface" => "mcp"} end, server: server)
        end)

      assert log =~ "the recorder is 100 rows behind"
      assert {:message_queue_len, 100} = Process.info(pid, :message_queue_len)
    end

    test "a queued row does not keep oversized input alive" do
      server = :"memory_#{System.unique_integer([:positive])}"
      pid = start_supervised!({QueryParseErrors, name: server})
      :ok = :sys.suspend(pid)
      big = String.duplicate("x", 1_000_000)
      sql = "SELECT FROM " <> big
      # A field that is short but points into a large binary.
      agent = binary_part(big, 0, 100)
      assert :binary.referenced_byte_size(agent) > byte_size(agent)
      error = %Guardian.AST.ParseError{reason: "test", row: 0, col: 0}

      :ok =
        QueryParseErrors.record(
          sql,
          error,
          fn -> %{"interface" => "http", "user_agent" => agent} end,
          server: server
        )

      {:messages, [{:"$gen_cast", {:record, row}}]} = Process.info(pid, :messages)

      for {_key, value} when is_binary(value) <- row do
        assert :binary.referenced_byte_size(value) == byte_size(value)
      end

      assert byte_size(row["sql"]) == QueryParseErrors.max_sql_bytes()
    end

    test "rows over the hourly cap are dropped and counted on the next recorded row" do
      now = :counters.new(1, [])
      :counters.put(now, 1, 3600 * 10)
      server = :"limiter_#{System.unique_integer([:positive])}"

      start_supervised!(
        {QueryParseErrors, name: server, rows_per_hour: 2, clock: fn -> :counters.get(now, 1) end}
      )

      sqls = for _ <- 1..5, do: bad_sql()

      log =
        capture_log(fn ->
          for sql <- sqls do
            error = %Guardian.AST.ParseError{reason: "test", row: 0, col: 0}

            assert QueryParseErrors.record(sql, error, fn -> %{"interface" => "http"} end,
                     server: server
                   ) == :ok
          end

          :ok = QueryParseErrors.sync(server)
        end)

      assert log =~ "2 rows already recorded this hour"
      assert [[_], [_], [], [], []] = Enum.map(sqls, &rows_for(&1, server))

      # Next hour: the first row reports the three dropped.
      :counters.add(now, 1, 3600)
      sql = bad_sql()
      error = %Guardian.AST.ParseError{reason: "test", row: 0, col: 0}

      :ok =
        QueryParseErrors.record(sql, error, fn -> %{"interface" => "http"} end, server: server)

      assert [%{"dropped_before" => 3}] = rows_for(sql, server)
    end
  end
end

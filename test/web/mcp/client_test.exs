defmodule Web.MCP.ClientTest do
  use ExUnit.Case, async: false
  import MCPTestClient

  @api_key Application.compile_env!(:guardian, :api_key)

  setup_all do
    wait_for_server()
    :ok
  end

  defp wait_for_server(retries \\ 10) do
    case Registry.lookup(Anubis.Server.Registry, {:server, Web.MCP.Server}) do
      [{_pid, _}] ->
        :ok

      [] when retries > 0 ->
        Process.sleep(50)
        wait_for_server(retries - 1)

      [] ->
        raise "MCP server not available after waiting"
    end
  end

  describe "initialization" do
    test "client connects and initializes" do
      MCPTestClient.start()

      # get_server_info returns the map directly (not wrapped in {:ok, ...})
      info = get_server_info()
      assert info["name"] == "guardian"
      assert info["version"] == "0.1.0"
    end
  end

  describe "tools/list" do
    test "returns available tools" do
      MCPTestClient.start()

      {:ok, response} = list_tools()
      tools = response.result["tools"]
      tool_names = Enum.map(tools, & &1["name"])

      assert tool_names == ["query", "send_events"]
      ingest = Enum.find(tools, &(&1["name"] == "send_events"))
      schema = ingest["inputSchema"]
      assert Enum.sort(schema["required"]) == ["events", "table"]
      assert schema["properties"]["events"]["items"]["type"] == "object"
      assert %{"const" => nil} in schema["properties"]["return_keys"]["oneOf"]
      assert ingest["description"] =~ "[a-z_][a-z0-9_]*"
      assert ingest["description"] =~ "not object keys"

      query = Enum.find(tools, &(&1["name"] == "query"))
      assert query["description"] =~ "schemaless event store"
      assert query["description"] =~ "UNION, JOIN, subqueries"
      assert query["description"] =~ "Columns are untyped"
      assert query["description"] =~ "'YYYY-MM-DD HH:MM:SS'"
      assert query["description"] =~ "guardian://query-language"
    end
  end

  describe "resources" do
    test "serves the query language reference" do
      MCPTestClient.start()

      {:ok, response} = list_resources()

      assert [%{"uri" => "guardian://query-language", "mimeType" => "text/markdown"}] =
               response.result["resources"]

      {:ok, response} = read_resource("guardian://query-language")
      [content] = response.result["contents"]
      assert content["mimeType"] == "text/markdown"
      assert content["text"] == File.read!("lib/web/mcp/query_language.md")
    end
  end

  describe "query tool" do
    test "executes SELECT query and returns list of maps" do
      MCPTestClient.start()
      table = "mcp_select_#{System.unique_integer([:positive])}"

      Engine.ingest_event(table, %{"name" => "alice", "score" => 10})
      Engine.ingest_event(table, %{"name" => "bob", "score" => 20})

      {:ok, response} =
        call_tool("query", %{"sql" => "SELECT name, score FROM #{table} ORDER BY score"})

      # Result should contain content with the query output
      [content | _] = response.result["content"]
      assert content["type"] == "text"
      parsed = Jason.decode!(content["text"])

      assert parsed == [
               %{"name" => "alice", "score" => 10},
               %{"name" => "bob", "score" => 20},
             ]
    end

    test "executes SHOW TABLES" do
      MCPTestClient.start()

      {:ok, response} =
        call_tool("query", %{"sql" => "SHOW TABLES"})

      assert response.result["content"]
    end

    test "returns error for invalid SQL" do
      MCPTestClient.start()

      {:ok, response} =
        call_tool("query", %{"sql" => "INVALID SQL QUERY"})

      assert response.result["isError"] == true
    end

    test "parse errors name the token found" do
      MCPTestClient.start()

      {:ok, response} =
        call_tool("query", %{"sql" => "SELECT a FROM t UNION SELECT b FROM t"})

      assert response.result["isError"] == true
      [content] = response.result["content"]
      assert content["text"] =~ "Expected end of statement, got UNION"
    end

    test "a Query.Error while running is a tool error with its message" do
      MCPTestClient.start()

      {:ok, response} = call_tool("query", %{"sql" => "SELECT max_n(1, -1)"})

      assert response.result["isError"] == true
      [content] = response.result["content"]
      assert content["text"] == "max_n: n must be a non-negative integer"
    end

    test "returns error for multi-statement queries" do
      MCPTestClient.start()

      {:ok, response} =
        call_tool(
          "query",
          %{"sql" => "SELECT * FROM foo; SELECT * FROM bar"}
        )

      assert response.result["isError"] == true
      [content | _] = response.result["content"]
      assert content["text"] =~ "single-statement"
    end

    test "executes GROUP BY with aggregation" do
      MCPTestClient.start()
      table = "mcp_aggregate_#{System.unique_integer([:positive])}"

      Engine.ingest_event(table, %{"category" => "A", "value" => 10})
      Engine.ingest_event(table, %{"category" => "A", "value" => 20})
      Engine.ingest_event(table, %{"category" => "B", "value" => 30})

      {:ok, response} =
        call_tool(
          "query",
          %{
            "sql" =>
              "SELECT category, sum(value) AS total FROM #{table} GROUP BY category ORDER BY category",
          }
        )

      [content | _] = response.result["content"]
      parsed = Jason.decode!(content["text"])

      assert parsed == [
               %{"category" => "A", "total" => 30},
               %{"category" => "B", "total" => 30},
             ]
    end
  end

  describe "send_events tool" do
    defp send_events(arguments) do
      {:ok, response} = call_tool("send_events", arguments)
      response.result
    end

    defp decoded_result(response) do
      refute response["isError"] == true
      [%{"type" => "text", "text" => text}] = response["content"]
      Jason.decode!(text)
    end

    test "ingests arbitrary nested keys and values unchanged and makes them queryable" do
      MCPTestClient.start()
      table = "mcp_ingest_#{System.unique_integer([:positive])}"

      event = %{
        "name" => "alice",
        "score" => 1.25,
        "custom key.雪" => "arbitrary value 🌱",
        "nested" => %{"sql" => "SELECT", "table" => false, "events" => [1, 2], "null" => nil},
        "items" => [%{"unusual-key" => "x"}, %{"unusual-key" => "y"}],
      }

      result = send_events(%{"table" => table, "events" => [event]}) |> decoded_result()
      assert result == %{"status" => 200, "results" => [%{"success" => true, "event" => event}]}

      stored =
        Storage.Flattening.flatten_event(event)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      assert Storage.dump_table(table) == [stored]

      {:ok, response} =
        call_tool("query", %{"sql" => "SELECT name, score FROM #{table}"})

      assert decoded_result(response.result) == [%{"name" => "alice", "score" => 1.25}]
    end

    test "mixed per-event failures continue in input order with HTTP-equivalent results" do
      MCPTestClient.start()
      table = "mcp_mixed_#{System.unique_integer([:positive])}"
      http_table = "http_mcp_mixed_#{System.unique_integer([:positive])}"

      events = [
        %{"value" => 1, "other" => "a"},
        nil,
        42,
        "bad",
        [],
        %{"value" => 2, "other" => "b"},
      ]

      arguments = %{"table" => table, "events" => events, "return_keys" => ["value"]}
      result = send_events(arguments) |> decoded_result()

      assert result == %{
               "status" => 200,
               "results" =>
                 [%{"success" => true, "event" => %{"value" => 1}}] ++
                   List.duplicate(
                     %{"success" => false, "error" => "event is not a JSON object"},
                     4
                   ) ++
                   [%{"success" => true, "event" => %{"value" => 2}}],
             }

      assert Storage.dump_table(table) == [hd(events), List.last(events)]

      conn =
        Plug.Test.conn(:post, "/api/json/send_events", Map.put(arguments, "table", http_table))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-api-key", @api_key)
        |> Web.MainRouter.call(nil)

      assert Jason.decode!(conn.resp_body) == result
    end

    test "storage call failures retain uncertain wording and continue later events" do
      MCPTestClient.start()
      table = "mcp_uncertain_#{System.unique_integer([:positive])}"
      segment_id = SegmentID.generate()

      segment =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, {:append, _row}} ->
              # Unregister without stopping: deletion would stop this fake segment.
              :sys.replace_state(Storage.MutableSegments, fn state ->
                true = :ets.delete(Storage.MutableSegments, segment_id)
                state
              end)

              exit(:mcp_ingest_test_failure)
          end
        end)

      :sys.replace_state(Storage.MutableSegments, fn state ->
        true = :ets.insert(Storage.MutableSegments, {segment_id, segment, table})
        state
      end)

      on_exit(fn ->
        # Kill first: deletion stops the segment, and this fake one does not answer.
        Process.exit(segment, :kill)
        Storage.MutableSegments.delete_segment(segment_id)
        Storage.delete_table(table)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert send_events(%{
                   "table" => table,
                   "events" => [%{"value" => 1}, %{"value" => 2}],
                 })
                 |> decoded_result() == %{
                   "status" => 200,
                   "results" => [
                     %{
                       "success" => false,
                       "error" => "internal error; the event may have been stored",
                     },
                     %{"success" => true, "event" => %{"value" => 2}},
                   ],
                 }
        end)

      assert log =~ "mcp_ingest_test_failure"
      assert Storage.dump_table(table) == [%{"value" => 2}]
    end

    test "preserves absent, null, selected and empty return_keys without filtering stored events" do
      MCPTestClient.start()
      event = %{"value" => 1, "nested" => %{"x" => 2}}

      for {options, expected} <- [
            {%{}, event},
            {%{"return_keys" => nil}, event},
            {%{"return_keys" => ["nested", "missing"]}, %{"nested" => %{"x" => 2}}},
            {%{"return_keys" => []}, %{}},
          ] do
        table = "mcp_keys_#{System.unique_integer([:positive])}"
        arguments = Map.merge(%{"table" => table, "events" => [event]}, options)

        assert send_events(arguments) |> decoded_result() == %{
                 "status" => 200,
                 "results" => [%{"success" => true, "event" => expected}],
               }

        assert Storage.dump_table(table) == [Storage.Flattening.flatten_event(event)]
      end
    end

    test "empty and all-failed batches remain successful tool calls" do
      MCPTestClient.start()
      table = "mcp_failed_#{System.unique_integer([:positive])}"

      assert send_events(%{"table" => table, "events" => []}) |> decoded_result() == %{
               "status" => 200,
               "results" => [],
             }

      assert send_events(%{"table" => table, "events" => [nil, false]}) |> decoded_result() ==
               %{
                 "status" => 200,
                 "results" =>
                   List.duplicate(
                     %{"success" => false, "error" => "event is not a JSON object"},
                     2
                   ),
               }

      assert Storage.dump_table(table) == []
    end

    test "malformed requests produce tool errors with messages before any writes" do
      MCPTestClient.start()
      table = "mcp_invalid_#{System.unique_integer([:positive])}"
      valid = %{"table" => table, "events" => [%{"value" => 1}]}

      arguments =
        [%{}, Map.delete(valid, "table"), Map.delete(valid, "events")] ++
          Enum.map([nil, 1, %{}, "events"], &Map.put(valid, "events", &1)) ++
          Enum.map([nil, 1, "Invalid", "a.b", "select", "schema"], &Map.put(valid, "table", &1)) ++
          Enum.map(
            [true, 1, "value", %{}, ["value", 1], [nil]],
            &Map.put(valid, "return_keys", &1)
          )

      for arguments <- arguments do
        response = send_events(arguments)
        assert response["isError"] == true
        [%{"type" => "text", "text" => message}] = response["content"]
        assert is_binary(message) and byte_size(message) > 0
        assert Storage.dump_table(table) == []
      end
    end

    test "existing router authentication rejects ingestion before it reaches the tool" do
      table = "mcp_auth_#{System.unique_integer([:positive])}"

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "send_events",
            "arguments" => %{"table" => table, "events" => [%{"value" => 1}]},
          },
        })

      for headers <- [[], [{"x-api-key", "wrong"}]] do
        conn =
          Enum.reduce(headers, Plug.Test.conn(:post, "/mcp", body), fn {key, value}, conn ->
            Plug.Conn.put_req_header(conn, key, value)
          end)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Web.MainRouter.call(nil)

        assert conn.status == 401
        assert Storage.dump_table(table) == []
      end
    end
  end

  describe "single event store" do
    defp json_request(path, body, user_agent \\ "single-store-test") do
      conn =
        Plug.Test.conn(:post, "https://localhost" <> path, body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-api-key", @api_key)
        |> Plug.Conn.put_req_header("user-agent", user_agent)
        |> Web.MainRouter.call(nil)

      Jason.decode!(conn.resp_body)
    end

    defp mcp_query(sql) do
      {:ok, response} = call_tool("query", %{"sql" => sql})
      [content | _] = response.result["content"]
      Jason.decode!(content["text"])
    end

    test "events sent through the JSON API are visible to MCP, JSON queries and the console" do
      MCPTestClient.start()
      table = "single_store_#{System.unique_integer([:positive])}"

      assert %{"status" => 200} =
               json_request("/api/json/send_events", %{
                 table: table,
                 events: [%{"name" => "alice", "score" => 10}, %{"name" => "bob", "score" => 20}],
               })

      sql = "SELECT name, score FROM #{table} ORDER BY score"

      assert mcp_query(sql) == [
               %{"name" => "alice", "score" => 10},
               %{"name" => "bob", "score" => 20},
             ]

      assert %{"rows" => [["alice", 10], ["bob", 20]]} =
               json_request("/api/json/query", %{query: sql})

      output = ExUnit.CaptureIO.capture_io(fn -> Console.query(sql) end)
      assert output =~ "alice"
      assert output =~ "bob"
    end

    test "system_stats is queryable through MCP and the JSON API" do
      MCPTestClient.start()
      :ok = SystemStats.record_metrics()

      assert [%{"count()" => mcp_count}] = mcp_query("SELECT count() FROM system_stats")
      assert mcp_count > 0

      assert %{"rows" => [[json_count]]} =
               json_request("/api/json/query", %{query: "SELECT count() FROM system_stats"})

      assert json_count > 0
    end

    test "request logs are queryable and carry no user namespace" do
      MCPTestClient.start()
      # web_requests outlives a test run, and other tests share the default user agent.
      user_agent = "request-log-test-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      json_request("/api/json/query", %{query: "SELECT 1"}, user_agent)

      rows =
        mcp_query("SELECT path FROM web_requests WHERE user_agent = '#{user_agent}'")

      assert [%{"path" => "/api/json/query"}] = rows
      refute Map.has_key?(Storage.schema("web_requests"), "user_id")
      refute Map.has_key?(Storage.schema("web_responses"), "user_id")
    end
  end
end

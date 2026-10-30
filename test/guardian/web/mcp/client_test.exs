defmodule Guardian.Web.MCP.ClientTest do
  # Not async: drives the shared MCP server, whose tool calls are serialized
  # (docs/changes/mcp-serialized-tool-calls.md).
  use ExUnit.Case, async: false
  import Guardian.Test.MCPClient

  @api_key Application.compile_env!(:guardian, :admin_api_key)
  @ingest_api_key Application.compile_env!(:guardian, :ingest_api_key)

  setup_all do
    Guardian.Test.Polling.eventually(fn ->
      is_pid(Process.whereis(Anubis.Server.Registry.supervisor_name(Guardian.Web.MCP.Server)))
    end)

    :ok
  end

  describe "initialization" do
    test "client connects and initializes" do
      Guardian.Test.MCPClient.start()

      # get_server_info returns the map directly (not wrapped in {:ok, ...})
      info = get_server_info()
      assert info["name"] == "guardian"
      assert info["version"] == "0.1.0"
    end
  end

  describe "tools/list" do
    test "returns available tools" do
      Guardian.Test.MCPClient.start()

      {:ok, response} = list_tools()
      tools = response.result["tools"]
      tool_names = Enum.map(tools, & &1["name"])

      assert tool_names == [
               "delete_rule",
               "list_rules",
               "query",
               "read_rule",
               "send_events",
               "write_rule",
             ]

      ingest = Enum.find(tools, &(&1["name"] == "send_events"))
      schema = ingest["inputSchema"]
      assert Enum.sort(schema["required"]) == ["events", "table"]
      assert schema["properties"]["events"]["items"]["type"] == "object"
      assert %{"const" => nil} in schema["properties"]["return_keys"]["oneOf"]
      assert %{"type" => "string"} in schema["properties"]["idempotency_key"]["oneOf"]
      assert ingest["description"] =~ "[a-z_][a-z0-9_]*"
      assert ingest["description"] =~ "not object keys"

      query = Enum.find(tools, &(&1["name"] == "query"))
      assert query["description"] =~ "schemaless event store"
      assert query["description"] =~ "UNION, JOIN, subqueries"
      assert query["description"] =~ "Columns are untyped"
      assert query["description"] =~ "'YYYY-MM-DD HH:MM:SS'"
      assert query["description"] =~ "guardian://query-language"

      rules = Enum.find(tools, &(&1["name"] == "write_rule"))["description"]

      for phrase <- [
            "TRACK name",
            "LOOKUP field",
            "ephemeral",
            "return_keys",
            "guardian://query-language",
          ] do
        assert rules =~ phrase
      end
    end
  end

  describe "resources" do
    test "serves the query language reference" do
      Guardian.Test.MCPClient.start()

      {:ok, response} = list_resources()

      assert [%{"uri" => "guardian://query-language", "mimeType" => "text/markdown"}] =
               response.result["resources"]

      {:ok, response} = read_resource("guardian://query-language")
      [content] = response.result["contents"]
      assert content["mimeType"] == "text/markdown"
      assert content["text"] == File.read!("lib/guardian/web/mcp/query_language.md")
    end
  end

  describe "query tool" do
    test "executes SELECT query and returns list of maps" do
      Guardian.Test.MCPClient.start()
      table = "mcp_select_#{System.unique_integer([:positive])}"

      Guardian.Engine.ingest_event(table, %{"name" => "alice", "score" => 10})
      Guardian.Engine.ingest_event(table, %{"name" => "bob", "score" => 20})

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

    test "a LET name standing for * returns every column" do
      Guardian.Test.MCPClient.start()
      table = "mcp_let_star_#{System.unique_integer([:positive])}"
      Guardian.Engine.ingest_event(table, %{"name" => "alice", "score" => 10})

      {:ok, response} = call_tool("query", %{"sql" => "LET x = *; SELECT x FROM #{table}"})

      [content] = response.result["content"]
      assert Jason.decode!(content["text"]) == [%{"name" => "alice", "score" => 10}]
    end

    test "executes SHOW TABLES" do
      Guardian.Test.MCPClient.start()

      {:ok, response} =
        call_tool("query", %{"sql" => "SHOW TABLES"})

      assert response.result["content"]
    end

    test "returns error for invalid SQL" do
      Guardian.Test.MCPClient.start()

      {:ok, response} =
        call_tool("query", %{"sql" => "INVALID SQL QUERY"})

      assert response.result["isError"] == true
    end

    test "parse errors name the token found" do
      Guardian.Test.MCPClient.start()

      {:ok, response} =
        call_tool("query", %{"sql" => "SELECT a FROM t UNION SELECT b FROM t"})

      assert response.result["isError"] == true
      [content] = response.result["content"]
      assert content["text"] =~ "Expected end of statement, got UNION"
    end

    test "a Guardian.Query.Error while running is a tool error with its message" do
      Guardian.Test.MCPClient.start()

      {:ok, response} = call_tool("query", %{"sql" => "SELECT max_n(1, -1)"})

      assert response.result["isError"] == true
      [content] = response.result["content"]
      assert content["text"] == "max_n: n must be a non-negative integer"
    end

    test "returns error for multi-statement queries" do
      Guardian.Test.MCPClient.start()

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
      Guardian.Test.MCPClient.start()
      table = "mcp_aggregate_#{System.unique_integer([:positive])}"

      Guardian.Engine.ingest_event(table, %{"category" => "A", "value" => 10})
      Guardian.Engine.ingest_event(table, %{"category" => "A", "value" => 20})
      Guardian.Engine.ingest_event(table, %{"category" => "B", "value" => 30})

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

    test "HTTP and MCP share same-node receipts and MCP conflicts are tool errors" do
      Guardian.Test.MCPClient.start()
      table = "mcp_retry_#{System.unique_integer([:positive])}"

      params = %{
        "table" => table,
        "events" => [%{"value" => 1}],
        "idempotency_key" => "cross-interface",
      }

      conn =
        Plug.Test.conn(:post, "/api/json/send_events", params)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-api-key", @api_key)
        |> Guardian.Web.MainRouter.call(nil)

      assert conn.status == 200

      assert send_events(params) |> decoded_result() ==
               %{"status" => 200, "duplicate" => true, "failed_events" => 0}

      assert send_events(Map.put(params, "events", [%{"value" => 2}]))["isError"] == true
      assert send_events(Map.put(params, "idempotency_key", ""))["isError"] == true
      assert Guardian.Storage.dump_table(table) == params["events"]

      other = Map.put(params, "idempotency_key", "mcp-first")
      assert %{"results" => [_]} = send_events(other) |> decoded_result()

      assert Guardian.Web.Ingest.send_events(other) ==
               {:ok, %{status: 200, duplicate: true, failed_events: 0}}

      assert length(Guardian.Storage.dump_table(table)) == 2
    end

    test "MCP reports pending HTTP claims as tool errors and acknowledges mixed failures" do
      Guardian.Test.MCPClient.start()
      table = "mcp_pending_#{System.unique_integer([:positive])}"
      events = [%{"value" => 1}, nil]
      token = make_ref()
      digest = :crypto.hash(:sha256, :erlang.term_to_binary({events, nil}, [:deterministic]))

      assert GenServer.call(
               Guardian.Web.IngestIdempotency,
               {:claim, {table, "pending"}, digest, token, System.monotonic_time(:millisecond)}
             ) ==
               :claimed

      params = %{"table" => table, "events" => events, "idempotency_key" => "pending"}
      response = send_events(params)
      assert response["isError"] == true
      assert [%{"text" => message}] = response["content"]
      assert message =~ "in flight"
      assert Guardian.Storage.dump_table(table) == []
      GenServer.cast(Guardian.Web.IngestIdempotency, {:cancel, token, self()})
      # A call from the claimant orders cancellation before the tool retry.
      _state = :sys.get_state(Guardian.Web.IngestIdempotency)
      assert %{"results" => [_, _]} = send_events(params) |> decoded_result()

      assert send_events(params) |> decoded_result() ==
               %{"status" => 200, "duplicate" => true, "failed_events" => 1}

      assert Guardian.Storage.dump_table(table) == [%{"value" => 1}]
    end

    test "ingests arbitrary nested keys and values, returning the flat row, and makes them queryable" do
      Guardian.Test.MCPClient.start()
      table = "mcp_ingest_#{System.unique_integer([:positive])}"

      event = %{
        "name" => "alice",
        "score" => 1.25,
        "custom key.雪" => "arbitrary value 🌱",
        "nested" => %{"sql" => "SELECT", "table" => false, "events" => [1, 2], "null" => nil},
        "items" => [%{"unusual-key" => "x"}, %{"unusual-key" => "y"}],
      }

      flat_row = Guardian.Storage.Flattening.flatten_event(event)
      result = send_events(%{"table" => table, "events" => [event]}) |> decoded_result()

      assert result == %{
               "status" => 200,
               "results" => [%{"success" => true, "event" => flat_row}],
             }

      stored = Map.reject(flat_row, fn {_key, value} -> is_nil(value) end)

      assert Guardian.Storage.dump_table(table) == [stored]

      {:ok, response} =
        call_tool("query", %{"sql" => "SELECT name, score FROM #{table}"})

      assert decoded_result(response.result) == [%{"name" => "alice", "score" => 1.25}]
    end

    test "mixed per-event failures continue in input order with HTTP-equivalent results" do
      Guardian.Test.MCPClient.start()
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

      assert Guardian.Storage.dump_table(table) == [hd(events), List.last(events)]

      conn =
        Plug.Test.conn(:post, "/api/json/send_events", Map.put(arguments, "table", http_table))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-api-key", @api_key)
        |> Guardian.Web.MainRouter.call(nil)

      assert Jason.decode!(conn.resp_body) == result
    end

    test "preserves absent, null, selected and empty return_keys without filtering stored events; a selected key names one exact column, null when missing" do
      Guardian.Test.MCPClient.start()
      event = %{"value" => 1, "nested" => %{"x" => 2}}
      flat_row = %{"value" => 1, "nested.x" => 2}

      for {options, expected} <- [
            {%{}, flat_row},
            {%{"return_keys" => nil}, flat_row},
            {%{"return_keys" => ["nested.x", "nested", "missing"]},
             %{"nested.x" => 2, "nested" => nil, "missing" => nil}},
            {%{"return_keys" => []}, %{}},
          ] do
        table = "mcp_keys_#{System.unique_integer([:positive])}"
        arguments = Map.merge(%{"table" => table, "events" => [event]}, options)

        assert send_events(arguments) |> decoded_result() == %{
                 "status" => 200,
                 "results" => [%{"success" => true, "event" => expected}],
               }

        assert Guardian.Storage.dump_table(table) == [
                 Guardian.Storage.Flattening.flatten_event(event),
               ]
      end
    end

    test "empty and all-failed batches remain successful tool calls" do
      Guardian.Test.MCPClient.start()
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

      assert Guardian.Storage.dump_table(table) == []
    end

    test "malformed requests produce tool errors with messages before any writes" do
      Guardian.Test.MCPClient.start()
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
        assert Guardian.Storage.dump_table(table) == []
      end
    end

    test "router authentication rejects ingestion, including with the ingest key, before the tool" do
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

      for headers <- [[], [{"x-api-key", "wrong"}], [{"x-api-key", @ingest_api_key}]] do
        conn =
          Enum.reduce(headers, Plug.Test.conn(:post, "/mcp", body), fn {key, value}, conn ->
            Plug.Conn.put_req_header(conn, key, value)
          end)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Guardian.Web.MainRouter.call(nil)

        assert conn.status == if(headers == [{"x-api-key", @ingest_api_key}], do: 403, else: 401)
        assert Guardian.Storage.dump_table(table) == []
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
        |> Guardian.Web.MainRouter.call(nil)

      Jason.decode!(conn.resp_body)
    end

    defp mcp_query(sql) do
      {:ok, response} = call_tool("query", %{"sql" => sql})
      [content | _] = response.result["content"]
      Jason.decode!(content["text"])
    end

    test "events sent through the JSON API are visible to MCP queries" do
      Guardian.Test.MCPClient.start()
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
    end

    test "system_stats is queryable through MCP" do
      Guardian.Test.MCPClient.start()
      :ok = Guardian.SystemStats.record_metrics()

      assert [%{"count()" => mcp_count}] = mcp_query("SELECT count() FROM system_stats")
      assert mcp_count > 0
    end

    test "request logs are queryable and carry no user namespace" do
      Guardian.Test.MCPClient.start()
      # web_requests outlives a test run, and other tests share the default user agent.
      user_agent = "request-log-test-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      json_request("/api/json/send_events", %{table: "request_log_test", events: []}, user_agent)

      rows =
        mcp_query("SELECT path FROM web_requests WHERE user_agent = '#{user_agent}'")

      assert [%{"path" => "/api/json/send_events"}] = rows
      refute Map.has_key?(Guardian.Storage.schema("web_requests"), "user_id")
      refute Map.has_key?(Guardian.Storage.schema("web_responses"), "user_id")
    end
  end
end

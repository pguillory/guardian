defmodule Guardian.JsonApiTest do
  # async: false because some tests switch query-parameter keys on.
  use ExUnit.Case, async: false

  import Guardian.QueryApiKeys

  @api_key Application.compile_env!(:guardian, :api_key)

  def json_get(location, query \\ []) do
    {api_key, query} = Keyword.pop(query, :api_key, "")

    conn =
      Plug.Test.conn(:get, "https://localhost" <> location <> "?" <> URI.encode_query(query))
      |> Plug.Conn.put_req_header("x-api-key", api_key)
      |> Guardian.Web.MainRouter.call(nil)

    Jason.decode!(conn.resp_body)
  end

  def json_post(location, query \\ []) do
    {api_key, query} = Keyword.pop(query, :api_key, "")
    query = Map.new(query)

    conn =
      Plug.Test.conn(:post, "https://localhost" <> location, query)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", api_key)
      |> Guardian.Web.MainRouter.call(nil)

    Jason.decode!(conn.resp_body)
  end

  test "/health answers without an API key; the JSON API still requires one" do
    conn = Plug.Test.conn(:get, "/health") |> Guardian.Web.MainRouter.call(nil)
    assert conn.status == 200
    assert conn.resp_body == "ok"

    conn = Plug.Test.conn(:get, "/api/json/status") |> Guardian.Web.MainRouter.call(nil)
    assert conn.status == 401
  end

  test "/api/json/send_events" do
    assert json_post("/api/json/send_events",
             api_key: @api_key,
             table: "events",
             events: [%{"test_string" => "abc", "test_number" => 123}],
             return_keys: ["test_string"]
           ) == %{
             "status" => 200,
             "results" => [%{"success" => true, "event" => %{"test_string" => "abc"}}],
           }
  end

  test "/api/json/send_events reports mixed outcomes with return_keys in input order" do
    table = "json_mixed_#{System.unique_integer([:positive])}"
    events = [%{"value" => 1, "other" => "a"}, nil, %{"value" => 2, "other" => "b"}]

    assert json_post("/api/json/send_events",
             api_key: @api_key,
             table: table,
             events: events,
             return_keys: ["value"]
           ) == %{
             "status" => 200,
             "results" => [
               %{"success" => true, "event" => %{"value" => 1}},
               %{"success" => false, "error" => "event is not a JSON object"},
               %{"success" => true, "event" => %{"value" => 2}},
             ],
           }

    assert Guardian.Storage.dump_table(table) == [Enum.at(events, 0), Enum.at(events, 2)]
  end

  test "/api/json/send_events accepts absent, null and empty return_keys" do
    event = %{"value" => 1, "nested" => %{"x" => 2}}

    for {keys, expected} <- [{[], event}, {[return_keys: nil], event}, {[return_keys: []], %{}}] do
      table = "json_keys_#{System.unique_integer([:positive])}"

      assert json_post(
               "/api/json/send_events",
               [api_key: @api_key, table: table, events: [event]] ++ keys
             ) == %{
               "status" => 200,
               "results" => [%{"success" => true, "event" => expected}],
             }

      assert Guardian.Storage.dump_table(table) == [%{"value" => 1, "nested.x" => 2}]
    end
  end

  test "/api/json/send_events returns 200 for empty and all-failed batches" do
    table = "json_failed_#{System.unique_integer([:positive])}"

    assert json_post("/api/json/send_events", api_key: @api_key, table: table, events: []) == %{
             "status" => 200,
             "results" => [],
           }

    assert json_post("/api/json/send_events", api_key: @api_key, table: table, events: [nil, 1]) ==
             %{
               "status" => 200,
               "results" =>
                 List.duplicate(%{"success" => false, "error" => "event is not a JSON object"}, 2),
             }

    assert Guardian.Storage.dump_table(table) == []
  end

  test "/api/json/send_events validates the entire request before storing anything" do
    table = "json_invalid_request_#{System.unique_integer([:positive])}"

    for body <-
          [
            [events: [%{"value" => 1}]],
            [table: table],
            [table: table, events: nil],
            [table: table, events: %{}],
            [table: table, events: "bad"],
          ] ++
            Enum.map([true, 1, "value", %{}, ["value", 1], [nil]], fn keys ->
              [table: table, events: [%{"value" => 1}], return_keys: keys]
            end) do
      result = json_post("/api/json/send_events", [api_key: @api_key] ++ body)
      assert %{"status" => 400, "info" => message} = result
      assert is_binary(message)
      assert Map.keys(result) |> Enum.sort() == ["info", "status"]
      assert Guardian.Storage.dump_table(table) == []
    end
  end

  test "/api/json/send_events rejects an invalid API key before storing events" do
    table = "json_unauthorized_#{System.unique_integer([:positive])}"

    assert json_post("/api/json/send_events",
             api_key: "wrong",
             table: table,
             events: [%{"value" => 1}]
           ) == %{"status" => 401, "info" => "unauthorized"}

    assert Guardian.Storage.dump_table(table) == []
  end

  test "/api/json/send_events rejects table names SQL cannot address" do
    for table <- ["a.b", "../escape", "a/b", "", 123, "my-events", "MyEvents", "1a", "select"] do
      result =
        json_post("/api/json/send_events",
          api_key: @api_key,
          table: table,
          events: [%{"x" => 1}]
        )

      assert result["status"] == 400, inspect(table)
      assert result["info"] =~ "invalid table name"
      assert result["info"] =~ "lowercase letters, digits, and underscores"
    end
  end

  describe "authentication before the body is read" do
    defp raw_post(path, body, headers) do
      conn =
        Enum.reduce(headers, Plug.Test.conn(:post, "https://localhost" <> path, body), fn
          {name, value}, conn -> Plug.Conn.put_req_header(conn, name, value)
        end)

      Guardian.Web.MainRouter.call(conn, nil)
    end

    test "requests without a valid key get 401 and their body is never parsed" do
      for headers <- [[], [{"x-api-key", "wrong"}]],
          body <- ["{not json", String.duplicate("x", 9_000_000), ~s({"query": "SELECT 1"})] do
        conn = raw_post("/api/json/query", body, [{"content-type", "application/json"} | headers])
        assert conn.status == 401
        assert %Plug.Conn.Unfetched{} = conn.body_params
      end

      conn = raw_post("/api/json/send_events", "{not json", [{"content-type", "text/plain"}])
      assert conn.status == 401
    end

    test "a list- or map-shaped api_key parameter gets 401 and is not printed" do
      marker = "API_KEY_PARAM_MARKER_7310"

      for allowed? <- [true, false], query <- ["api_key[]=#{marker}", "api_key[a]=#{marker}"] do
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            with_query_api_keys(allowed?, fn ->
              conn = raw_post("/api/json/query?" <> query, ~s({"query": "SELECT 1"}), [])
              assert conn.status == 401
            end)
          end)

        refute output =~ marker
      end
    end

    test "a valid key in the header, or in the query string when allowed, reaches the body" do
      body = ~s({"query": "SELECT 1"})
      headers = [{"content-type", "application/json"}]

      conn = raw_post("/api/json/query", body, [{"x-api-key", @api_key} | headers])
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["rows"] == [[1]]

      with_query_api_keys(true, fn ->
        conn = raw_post("/api/json/query?api_key=#{@api_key}", body, headers)
        assert conn.status == 200
      end)

      with_query_api_keys(false, fn ->
        conn = raw_post("/api/json/query?api_key=#{@api_key}", body, headers)
        assert {conn.status, Jason.decode!(conn.resp_body)["info"]} == {401, "api_key required"}
        assert %Plug.Conn.Unfetched{} = conn.body_params
      end)
    end

    test "web_requests records where the key was found, never the key" do
      table = "web_requests"
      marker = "auth-method-#{System.unique_integer([:positive])}"
      body = ~s({"query": "SELECT 1"})
      json = {"content-type", "application/json"}
      agent = {"user-agent", marker}

      assert raw_post("/api/json/query", body, [{"x-api-key", @api_key}, json, agent]).status ==
               200

      with_query_api_keys(true, fn ->
        assert raw_post("/api/json/query?api_key=#{@api_key}", body, [json, agent]).status ==
                 200
      end)

      {:ok, _labels, rows} =
        Guardian.Query.execute("SELECT auth_method FROM #{table} WHERE user_agent = '#{marker}'")

      assert Enum.sort(List.flatten(rows)) == ["header", "query"]
      refute inspect(rows) =~ @api_key
    end

    # The status and `info` of an error response. The auth plug sends it and halts; for
    # errors answered by handle_errors/2, Plug.ErrorHandler sends it and then reraises.
    defp error_response(path, body, headers) do
      conn = raw_post(path, body, headers)
      assert conn.halted
      # Consume the response message Plug.Test sends, as the rescue below does.
      assert_received {_ref, {_status, _headers, _body}}
      {conn.status, Jason.decode!(conn.resp_body)["info"]}
    rescue
      Plug.Conn.WrapperError ->
        assert_received {_ref, {status, _headers, body}}
        {status, Jason.decode!(body)["info"]}
    end

    test "with a key, body failures get 400, 413, or 415 with a fixed message" do
      key = {"x-api-key", @api_key}
      json = {"content-type", "application/json"}

      assert error_response("/api/json/query", "{not json", [key, json]) ==
               {400, "malformed JSON body"}

      assert error_response("/api/json/query", String.duplicate("x", 9_000_000), [key, json]) ==
               {413, "request body over 8 MB"}

      assert error_response("/api/json/query", "x", [key, {"content-type", "text/plain"}]) ==
               {415, "unsupported content type; send application/json"}
    end

    test "with query keys off, a request without the header is 401 whatever its query string" do
      json = {"content-type", "application/json"}
      body = ~s({"query": "SELECT 1"})
      nested = "x" <> String.duplicate("[a]", 40) <> "=1"
      long = "x=" <> String.duplicate("a", 1_000_000)

      with_query_api_keys(false, fn ->
        for query <- ["x=%FF", nested, long] do
          output =
            ExUnit.CaptureIO.capture_io(fn ->
              assert error_response("/api/json/query?" <> query, body, [json]) ==
                       {401, "api_key required"}
            end)

          assert output == ""
        end
      end)
    end

    test "an undecodable query string gets 400 with a fixed message, and nothing is printed" do
      with_query_api_keys(true, &undecodable_query_string_cases/0)
    end

    defp undecodable_query_string_cases do
      key = {"x-api-key", @api_key}
      json = {"content-type", "application/json"}
      body = ~s({"query": "SELECT 1"})
      nested = "x" <> String.duplicate("[a]", 40) <> "=1"

      for {query, headers} <- [
            # No header: the key check decodes the query string.
            {"x=%FF", [json]},
            {nested, [json]},
            # A valid header: Plug.Parsers decodes it after the key check.
            {"x=%FF", [key, json]},
            {nested, [key, json]},
          ] do
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            assert error_response("/api/json/query?" <> query, body, headers) ==
                     {400, "invalid query string"}
          end)

        assert output == ""
      end

      long = "x=" <> String.duplicate("a", 1_000_000)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert error_response("/api/json/query?" <> long, body, [key, json]) ==
                   {414, "invalid query string"}

          assert error_response("/api/json/query?" <> long, body, [json]) ==
                   {414, "invalid query string"}
        end)

      assert output == ""
    end

    test "a wrong key header gets 401 without the query string being decoded" do
      headers = [{"x-api-key", "wrong"}, {"content-type", "application/json"}]
      conn = raw_post("/api/json/query?x=%FF", ~s({"query": "SELECT 1"}), headers)
      assert {conn.status, Jason.decode!(conn.resp_body)["info"]} == {401, "unauthorized"}
      assert %Plug.Conn.Unfetched{} = conn.query_params
    end

    test "a /query body without a string query gets 400, and the body is not printed" do
      key = {"x-api-key", @api_key}
      json = {"content-type", "application/json"}
      marker = "QUERY_BODY_MARKER_5521"
      info = ~s(the body must be a JSON object with a string "query")

      for {body, headers} <- [
            {~s({"sql": "#{marker}"}), [key, json]},
            {~s({"query": ["#{marker}"]}), [key, json]},
            {~s({"query": null}), [key, json]},
            {~s(["#{marker}"]), [key, json]},
            {~s({"query": "#{marker}"}), [key]},
          ] do
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            conn = raw_post("/api/json/query", body, headers)
            assert {conn.status, Jason.decode!(conn.resp_body)["info"]} == {400, info}
          end)

        refute output =~ marker
      end
    end

    test "CORS preflight is still answered without a key" do
      conn =
        Plug.Test.conn(:options, "https://localhost/api/json/query")
        |> Plug.Conn.put_req_header("origin", "https://example.com")
        |> Plug.Conn.put_req_header("access-control-request-method", "POST")
        |> Guardian.Web.MainRouter.call(nil)

      assert conn.status == 204
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") != []
    end
  end

  test "/api/json/query" do
    table = "json_query_#{System.unique_integer([:positive])}"

    # Insert some test events
    Guardian.Engine.ingest_event(table, %{"ip" => "1.2.3.4", "status" => 404})
    Guardian.Engine.ingest_event(table, %{"ip" => "1.2.3.4", "status" => 404})
    Guardian.Engine.ingest_event(table, %{"ip" => "5.6.7.8", "status" => 404})

    # Query the data
    result =
      json_post("/api/json/query",
        api_key: @api_key,
        query:
          "SELECT ip, count() FROM #{table} WHERE status = 404 GROUP BY ip ORDER BY count() DESC"
      )

    assert result["status"] == 200
    assert result["columns"] == ["ip", "count()"]
    assert result["rows"] == [["1.2.3.4", 2], ["5.6.7.8", 1]]
  end

  test "/api/json/query answers query errors with 400 and the message" do
    table = "json_query_error_#{System.unique_integer([:positive])}"
    Guardian.Engine.ingest_event(table, %{"v" => 1})

    result =
      json_post("/api/json/query", api_key: @api_key, query: "SELECT test_raise(v) FROM #{table}")

    assert result["status"] == 400
    assert result["info"] =~ "query evaluation failed"
  end

  test "/api/json/query resolves SELECT *, SHOW TABLES, DESC, and LET" do
    table = "json_resolve_#{System.unique_integer([:positive])}"
    Guardian.Engine.ingest_event(table, %{"a" => 1, "b" => "x"})

    query = fn source -> json_post("/api/json/query", api_key: @api_key, query: source) end

    assert query.("SELECT * FROM #{table}") == %{
             "status" => 200,
             "columns" => ["a", "b"],
             "rows" => [[1, "x"]],
           }

    assert %{"status" => 200, "columns" => ["table"], "rows" => tables} = query.("SHOW TABLES")
    assert [table] in tables

    assert query.("DESC #{table}") == %{
             "status" => 200,
             "columns" => ["key"],
             "rows" => [["a"], ["b"]],
           }

    assert query.("LET n = a + 1; SELECT n FROM #{table}") == %{
             "status" => 200,
             "columns" => ["n"],
             "rows" => [[2]],
           }

    assert query.("SELECT 1;") == %{"status" => 200, "columns" => ["1"], "rows" => [[1]]}

    assert query.("SELECT 1; SELECT 2") == %{
             "status" => 400,
             "info" => "Only single-statement queries are supported",
           }

    assert query.("LET n = 1") == %{
             "status" => 400,
             "info" => "Query resolved to no executable statements",
           }

    assert query.("") == %{
             "status" => 400,
             "info" => "Query resolved to no executable statements",
           }
  end

  test "/api/json/query matches column names ignoring case" do
    table = "json_case_#{System.unique_integer([:positive])}"
    Guardian.Engine.ingest_event(table, %{"userId" => 7, "user" => %{"firstName" => "Bob"}})

    assert json_post("/api/json/query",
             api_key: @api_key,
             query: "SELECT USERID, user.firstname FROM #{table}"
           ) == %{
             "status" => 200,
             "columns" => ["userId", "user.firstName"],
             "rows" => [[7, "Bob"]],
           }
  end

  test "404" do
    assert json_get("/api/json/wrong", api_key: @api_key) == %{
             "status" => 404,
           }
  end

  test "rejects an invalid API key" do
    assert json_get("/api/json/wrong", api_key: "wrong") == %{
             "status" => 401,
             "info" => "unauthorized",
           }
  end
end

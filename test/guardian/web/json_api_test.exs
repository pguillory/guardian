defmodule Guardian.Web.JsonApiTest do
  # Not async: requests write the shared web_requests and web_responses tables.
  use ExUnit.Case, async: false
  import Guardian.Web.JsonApi

  @admin_api_key Application.compile_env!(:guardian, :admin_api_key)
  @ingest_api_key Application.compile_env!(:guardian, :ingest_api_key)

  # A valid send_events body that stores nothing.
  @empty_batch ~s({"table": "json_auth", "events": []})

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
             api_key: @admin_api_key,
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
             api_key: @admin_api_key,
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

  test "/api/json/send_events leaves a dropped value out of the result; return_keys reads it as null" do
    table = "json_dropped_#{System.unique_integer([:positive])}"
    event = %{"ok" => 1, "big" => 2 ** 64, "nested" => %{"big" => 2 ** 64, "ok" => true}}

    for {keys, expected} <- [
          {[], %{"ok" => 1, "nested.ok" => true}},
          {[return_keys: ["big", "nested.big", "ok"]],
           %{"big" => nil, "nested.big" => nil, "ok" => 1}},
        ] do
      assert json_post(
               "/api/json/send_events",
               [api_key: @admin_api_key, table: table, events: [event]] ++ keys
             ) == %{
               "status" => 200,
               "results" => [%{"success" => true, "event" => expected}],
             }
    end
  end

  test "/api/json/send_events returns the flat stored row and reads return_keys as exact columns" do
    event = %{"value" => 1, "nested" => %{"x" => 2}}
    flat_row = %{"value" => 1, "nested.x" => 2}

    for {keys, expected} <- [
          {[], flat_row},
          {[return_keys: nil], flat_row},
          {[return_keys: ["nested.x", "nested"]], %{"nested.x" => 2, "nested" => nil}},
          {[return_keys: []], %{}},
        ] do
      table = "json_keys_#{System.unique_integer([:positive])}"

      assert json_post(
               "/api/json/send_events",
               [api_key: @admin_api_key, table: table, events: [event]] ++ keys
             ) == %{
               "status" => 200,
               "results" => [%{"success" => true, "event" => expected}],
             }

      assert Guardian.Storage.dump_table(table) == [%{"value" => 1, "nested.x" => 2}]
    end
  end

  test "/api/json/send_events returns 200 for empty and all-failed batches" do
    table = "json_failed_#{System.unique_integer([:positive])}"

    assert json_post("/api/json/send_events", api_key: @admin_api_key, table: table, events: []) ==
             %{
               "status" => 200,
               "results" => [],
             }

    assert json_post("/api/json/send_events",
             api_key: @admin_api_key,
             table: table,
             events: [nil, 1]
           ) ==
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
      result = json_post("/api/json/send_events", [api_key: @admin_api_key] ++ body)
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
          api_key: @admin_api_key,
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
          body <- ["{not json", String.duplicate("x", 9_000_000), @empty_batch] do
        conn =
          raw_post("/api/json/send_events", body, [{"content-type", "application/json"} | headers])

        assert conn.status == 401
        assert %Plug.Conn.Unfetched{} = conn.body_params
      end

      conn = raw_post("/api/json/send_events", "{not json", [{"content-type", "text/plain"}])
      assert conn.status == 401
    end

    test "a list- or map-shaped api_key parameter gets 401 and is not printed" do
      marker = "API_KEY_PARAM_MARKER_7310"

      for query <- ["api_key[]=#{marker}", "api_key[a]=#{marker}"] do
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            conn = raw_post("/api/json/send_events?" <> query, @empty_batch, [])
            assert conn.status == 401
          end)

        refute output =~ marker
      end
    end

    test "a valid key in the header reaches the body; one in the query string is ignored" do
      body = @empty_batch
      headers = [{"content-type", "application/json"}]

      conn = raw_post("/api/json/send_events", body, [{"x-api-key", @admin_api_key} | headers])
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["results"] == []

      for key <- [@admin_api_key, @ingest_api_key] do
        conn = raw_post("/api/json/send_events?api_key=#{key}", body, headers)
        assert {conn.status, Jason.decode!(conn.resp_body)["info"]} == {401, "api_key required"}
        assert %Plug.Conn.Unfetched{} = conn.body_params
      end
    end

    test "web_requests records which key, never the key" do
      table = "web_requests"
      marker = "auth-method-#{System.unique_integer([:positive])}"
      body = @empty_batch
      json = {"content-type", "application/json"}
      agent = {"user-agent", marker}

      for key <- [@admin_api_key, @ingest_api_key] do
        assert raw_post("/api/json/send_events", body, [{"x-api-key", key}, json, agent]).status ==
                 200
      end

      {:ok, _labels, rows} =
        Guardian.Query.execute(
          "SELECT auth_method, auth_key FROM #{table} WHERE user_agent = '#{marker}'"
        )

      # auth_method is no longer recorded: the header is the only way to send a key.
      assert Enum.sort(rows) == [[nil, "admin"], [nil, "ingest"]]

      for key <- [@admin_api_key, @ingest_api_key], do: refute(inspect(rows) =~ key)
    end

    # Authentication sends a response and halts; a body failure sends one and reraises,
    # which Bandit handles (quietly, under 500).
    defp error_response(path, body, headers) do
      conn =
        try do
          raw_post(path, body, headers)
        rescue
          _raised_after_answering -> nil
        end

      assert_received {_ref, {status, _headers, response_body}}
      if conn, do: assert(conn.halted)
      {status, Jason.decode!(response_body)["info"]}
    end

    test "with a key, body failures get 400, 413, or 415 with a fixed message" do
      key = {"x-api-key", @admin_api_key}
      json = {"content-type", "application/json"}

      assert error_response("/api/json/send_events", "{not json", [key, json]) ==
               {400, "malformed JSON body"}

      assert error_response("/api/json/send_events", String.duplicate("x", 9_000_000), [key, json]) ==
               {413, "request body over 8 MB"}

      assert error_response("/api/json/send_events", "x", [key, {"content-type", "text/plain"}]) ==
               {415, "unsupported content type; send application/json"}
    end

    test "a request without the header is 401 whatever its query string" do
      json = {"content-type", "application/json"}
      body = @empty_batch
      nested = "x" <> String.duplicate("[a]", 40) <> "=1"
      long = "x=" <> String.duplicate("a", 1_000_000)

      for query <- ["x=%FF", nested, long] do
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            assert error_response("/api/json/send_events?" <> query, body, [json]) ==
                     {401, "api_key required"}
          end)

        assert output == ""
      end
    end

    test "with a key, an undecodable query string gets 400 or 414 with a fixed message" do
      key = {"x-api-key", @admin_api_key}
      json = {"content-type", "application/json"}
      body = @empty_batch
      nested = "x" <> String.duplicate("[a]", 40) <> "=1"

      # Plug.Parsers decodes the query string after the key check.
      for query <- ["x=%FF", nested] do
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            assert error_response("/api/json/send_events?" <> query, body, [key, json]) ==
                     {400, "invalid query string"}
          end)

        assert output == ""
      end

      long = "x=" <> String.duplicate("a", 1_000_000)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert error_response("/api/json/send_events?" <> long, body, [key, json]) ==
                   {414, "invalid query string"}
        end)

      assert output == ""
    end

    test "a wrong key header gets 401 without the query string being decoded" do
      headers = [{"x-api-key", "wrong"}, {"content-type", "application/json"}]
      conn = raw_post("/api/json/send_events?x=%FF", @empty_batch, headers)
      assert {conn.status, Jason.decode!(conn.resp_body)["info"]} == {401, "unauthorized"}
      assert %Plug.Conn.Unfetched{} = conn.query_params
    end

    test "CORS preflight is still answered without a key" do
      conn =
        Plug.Test.conn(:options, "https://localhost/api/json/send_events")
        |> Plug.Conn.put_req_header("origin", "https://example.com")
        |> Plug.Conn.put_req_header("access-control-request-method", "POST")
        |> Guardian.Web.MainRouter.call(nil)

      assert conn.status == 204
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") != []
    end
  end

  describe "key scope" do
    defp scoped_request(method, path, key) do
      Plug.Test.conn(method, "https://localhost" <> path, @empty_batch)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", key)
      |> Guardian.Web.MainRouter.call(nil)
    end

    test "every key can send events" do
      for key <- [@admin_api_key, @ingest_api_key] do
        conn = scoped_request(:post, "/api/json/send_events", key)
        assert {conn.status, Jason.decode!(conn.resp_body)["results"]} == {200, []}
      end
    end

    test "the ingest key gets 403 everywhere else in the JSON API, without its body read" do
      forbidden = %{"status" => 403, "info" => "this key can only send events"}

      for {method, path} <- [
            {:post, "/api/json/query"},
            {:get, "/api/json/send_events"},
            {:post, "/api/json/send_events/x"},
            {:post, "/api/json/anything"},
          ] do
        conn = scoped_request(method, path, @ingest_api_key)
        assert {conn.status, Jason.decode!(conn.resp_body)} == {403, forbidden}
        assert %Plug.Conn.Unfetched{} = conn.body_params
      end
    end

    test "the JSON query endpoint is gone: the admin key gets 404" do
      conn = scoped_request(:post, "/api/json/query", @admin_api_key)
      assert {conn.status, Jason.decode!(conn.resp_body)} == {404, %{"status" => 404}}
    end
  end

  test "a response already sent is preserved when a failure follows it" do
    conn =
      Plug.Test.conn(:get, "/status")
      |> Plug.Conn.put_req_header("x-api-key", @admin_api_key)
      |> Plug.Conn.send_resp(202, "already sent")

    assert_raise Plug.Conn.AlreadySentError, fn -> call(conn, []) end
    assert_received {_ref, {202, _headers, "already sent"}}
    refute_received {_ref, {_status, _headers, _body}}
  end

  test "body failures answer with JSON and say the connection closes" do
    conn =
      Plug.Test.conn(:post, "/send_events", "{malformed")
      |> Plug.Conn.put_req_header("x-api-key", @admin_api_key)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert_raise Plug.Parsers.ParseError, fn -> call(conn, []) end
    assert_received {_ref, {400, headers, body}}
    assert {"connection", "close"} in headers
    assert Jason.decode!(body)["info"] == "malformed JSON body"
  end

  test "an unexpected failure is a 500, logged by Bandit, without the API key" do
    table = "json_crash_#{System.unique_integer([:positive])}"
    marker = "crash_marker_#{System.unique_integer([:positive])}"
    Guardian.Test.Segments.intercept_append(table, fn _from, _row -> exit(marker) end)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Guardian.Web.bound_port(), [:binary, active: false], 2000)

    on_exit(fn -> :gen_tcp.close(socket) end)
    body = Jason.encode!(%{table: table, events: [%{"x" => 1}]})

    log =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        :ok =
          :gen_tcp.send(socket, [
            "POST /api/json/send_events HTTP/1.1\r\nHost: localhost\r\n",
            "x-api-key: ",
            @admin_api_key,
            "\r\nContent-Type: application/json\r\n",
            "Content-Length: #{byte_size(body)}\r\n\r\n",
            body,
          ])

        response = receive_until_closed(socket, "")
        [headers, response_body] = String.split(response, "\r\n\r\n", parts: 2)
        assert headers =~ "HTTP/1.1 500"
        assert Jason.decode!(response_body) == %{"status" => 500}
        Logger.flush()
      end)

    assert log =~ marker
    refute log =~ @admin_api_key
  end

  test "transport and protocol failures reach Bandit without a response" do
    for authenticated? <- [false, true],
        error <- [
          %Bandit.TransportError{message: "client closed", error: :closed},
          %Bandit.HTTPError{message: "read timed out", plug_status: :request_timeout},
          %Bandit.HTTP2.Errors.StreamError{
            message: "stream reset",
            error_code: 0x1,
            stream_id: 1,
          },
          %Bandit.HTTP2.Errors.ConnectionError{message: "connection reset", error_code: 0x1},
        ] do
      conn = Plug.Test.conn(:get, "/status")

      conn =
        if authenticated?,
          do: Plug.Conn.put_req_header(conn, "x-api-key", @admin_api_key),
          else: conn

      conn = Plug.Conn.register_before_send(conn, fn _conn -> raise error end)

      caught = catch_error(call(conn, []))
      assert unwrapped(caught) == error
      refute_received {_ref, {_status, _headers, _body}}
    end
  end

  defp unwrapped(%Plug.Conn.WrapperError{reason: reason}) do
    reason
  end

  defp unwrapped(error) do
    error
  end

  test "the real HTTP listener accepts a JSON batch sent as one-byte chunks" do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Guardian.Web.bound_port(), [:binary, active: false], 2000)

    on_exit(fn -> :gen_tcp.close(socket) end)
    body = Jason.encode!(%{table: "json_chunked", events: [%{"x" => 1}], return_keys: ["x"]})
    chunks = for <<byte <- body>>, do: ["1\r\n", <<byte>>, "\r\n"]

    log =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        :ok =
          :gen_tcp.send(socket, [
            "POST /api/json/send_events HTTP/1.1\r\nHost: localhost\r\n",
            "x-api-key: ",
            @admin_api_key,
            "\r\nContent-Type: application/json\r\n",
            "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
            chunks,
            "0\r\n\r\n",
          ])

        response = receive_until_closed(socket, "")
        [headers, response_body] = String.split(response, "\r\n\r\n", parts: 2)
        assert headers =~ "HTTP/1.1 200 OK\r\n"

        assert Jason.decode!(response_body) == %{
                 "status" => 200,
                 "results" => [%{"success" => true, "event" => %{"x" => 1}}],
               }

        Logger.flush()
      end)

    refute log =~ "** ("
  end

  test "a split malformed body with Expect closes promptly on the real HTTP listener" do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Guardian.Web.bound_port(), [:binary, active: false], 2000)

    on_exit(fn -> :gen_tcp.close(socket) end)
    body = "[" <> String.duplicate(" ", 70_000) <> "BODY_SECRET_9421"

    log =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        :ok =
          :gen_tcp.send(socket, [
            "POST /api/json/send_events HTTP/1.1\r\nHost: localhost\r\n",
            "x-api-key: ",
            @admin_api_key,
            "\r\nContent-Type: application/json\r\n",
            "Content-Length: ",
            Integer.to_string(byte_size(body)),
            "\r\n",
            "Expect: 100-continue\r\n\r\n",
          ])

        # The interim response proves Bandit consumed the headers before any body
        # bytes arrived. The direct boundary test above separately pins our close
        # header: Bandit also closes a stale adapter with an unhonored Expect flag.
        assert receive_headers(socket, "") =~ "HTTP/1.1 100 Continue\r\n"
        :ok = :gen_tcp.send(socket, body)
        response = receive_until_closed(socket, "")
        assert response =~ "HTTP/1.1 400 Bad Request"
        assert response =~ "connection: close"
        assert response =~ "malformed JSON body"
        Logger.flush()
      end)

    refute log =~ "BODY_SECRET_9421"
  end

  defp receive_headers(socket, acc) do
    if String.ends_with?(acc, "\r\n\r\n") do
      acc
    else
      assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
      receive_headers(socket, acc <> bytes)
    end
  end

  defp receive_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, bytes} -> receive_until_closed(socket, acc <> bytes)
      {:error, :closed} -> acc
      other -> flunk("expected the HTTP connection to close, got #{inspect(other)}")
    end
  end

  test "404" do
    assert json_get("/api/json/wrong", api_key: @admin_api_key) == %{
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

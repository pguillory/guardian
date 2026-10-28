defmodule Guardian.Web.AuthRoutesTest do
  # Each well-formed credential form against both authenticated routers, with the
  # exact 401 and 403 responses, so how a key is accepted cannot drift between them.
  # Both requests need full access (a JSON path other than POST /send_events, and
  # /mcp), so the ingest key is forbidden on both.
  # The credential forms are checked with query-parameter keys both allowed and
  # refused, a global setting, so this module is not async.
  use ExUnit.Case, async: false

  import Guardian.Test.QueryApiKeys

  @api_key Application.compile_env!(:guardian, :api_key)
  @admin_api_key Application.compile_env!(:guardian, :admin_api_key)
  @ingest_api_key Application.compile_env!(:guardian, :ingest_api_key)

  @json_missing ~s({"info":"api_key required","status":401}\n)
  @json_unauthorized ~s({"info":"unauthorized","status":401}\n)
  @mcp_missing ~s({"error":"api_key required"})
  @mcp_unauthorized ~s({"error":"unauthorized"})
  @json_forbidden ~s({"info":"this key can only send events","status":403}\n)
  @mcp_forbidden ~s({"error":"this key can only send events"})

  # {description, query string, x-api-key headers in order, expected outcome}, with
  # query keys allowed.
  defp cases(true) do
    cases()
  end

  # With query keys refused, a query-parameter key counts as no key at all.
  defp cases(false) do
    for {description, query, keys, expected} <- cases() do
      expected = if keys == [] and expected != :missing, do: :missing, else: expected
      {description, query, keys, expected}
    end
  end

  defp cases do
    [
      {"no key", "", [], :missing},
      {"an empty header", "", [""], :unauthorized},
      {"a wrong header", "", ["wrong"], :unauthorized},
      {"a valid header", "", [@api_key], :ok},
      {"a valid admin header", "", [@admin_api_key], :ok},
      {"a valid ingest header", "", [@ingest_api_key], :forbidden},
      {"a valid ingest query parameter", "api_key=#{@ingest_api_key}", [], :forbidden},
      {"a valid admin query parameter", "api_key=#{@admin_api_key}", [], :ok},
      {"a valid query parameter", "api_key=#{@api_key}", [], :ok},
      {"a wrong query parameter", "api_key=wrong", [], :unauthorized},
      {"an empty query parameter", "api_key=", [], :unauthorized},
      {"a wrong header over a valid query parameter", "api_key=#{@api_key}", ["wrong"],
       :unauthorized},
      {"a valid header over a wrong query parameter", "api_key=wrong", [@api_key], :ok},
      {"a wrong first header before a valid one", "", ["wrong", @api_key], :unauthorized},
      {"a valid first header before a wrong one", "", [@api_key, "wrong"], :ok},
      {"an ingest header before an admin one", "", [@ingest_api_key, @admin_api_key], :forbidden},
      {"a list-shaped query parameter", "api_key[]=#{@api_key}", [], :unauthorized},
      {"a map-shaped query parameter", "api_key[a]=#{@api_key}", [], :unauthorized},
      {"another query parameter only", "key=#{@api_key}", [], :missing},
    ]
  end

  defp request(path, query, keys) do
    url = if query == "", do: path, else: path <> "?" <> query
    conn = Plug.Test.conn(:get, "https://localhost" <> url)
    headers = Enum.map(keys, &{"x-api-key", &1})
    Guardian.Web.MainRouter.call(%{conn | req_headers: headers ++ conn.req_headers}, nil)
  end

  test "the JSON API accepts and rejects each credential form" do
    for allowed? <- [true, false],
        {description, query, keys, expected} <- cases(allowed?) do
      description = "#{description} (query keys allowed: #{allowed?})"
      conn = with_query_api_keys(allowed?, fn -> request("/api/json/wrong", query, keys) end)

      case expected do
        :ok ->
          assert conn.status == 404, description

        :missing ->
          assert {conn.status, conn.resp_body} == {401, @json_missing}, description

        :unauthorized ->
          assert {conn.status, conn.resp_body} == {401, @json_unauthorized}, description

        :forbidden ->
          assert {conn.status, conn.resp_body} == {403, @json_forbidden}, description
      end

      if expected != :ok do
        assert Plug.Conn.get_resp_header(conn, "content-type") ==
                 ["application/json; charset=utf-8"],
               description
      end
    end
  end

  test "the MCP endpoint accepts and rejects each credential form" do
    for allowed? <- [true, false],
        {description, query, keys, expected} <- cases(allowed?) do
      description = "#{description} (query keys allowed: #{allowed?})"
      conn = with_query_api_keys(allowed?, fn -> request("/mcp", query, keys) end)

      case expected do
        :ok ->
          # Past authentication, a GET is refused by the MCP router's method check.
          assert conn.status == 405, description

        :missing ->
          assert {conn.status, conn.resp_body} == {401, @mcp_missing}, description

        :unauthorized ->
          assert {conn.status, conn.resp_body} == {401, @mcp_unauthorized}, description

        :forbidden ->
          assert {conn.status, conn.resp_body} == {403, @mcp_forbidden}, description
      end

      if expected != :ok do
        assert Plug.Conn.get_resp_header(conn, "content-type") ==
                 ["application/json; charset=utf-8"],
               description
      end
    end
  end

  test "MCP logs a query-parameter key's use, never the key; a header key logs nothing" do
    log =
      capture_auth_note_log(fn ->
        with_query_api_keys(true, fn ->
          assert request("/mcp", "", [@api_key]).status == 405
          assert request("/mcp", "api_key=#{@api_key}", []).status == 405
        end)
      end)

    assert query_key_log_lines(log) == [
             "A request on /mcp authenticated with the api_key query parameter",
           ]

    refute log =~ @api_key

    log =
      capture_auth_note_log(fn ->
        assert request("/mcp", "", [@api_key]).status == 405
      end)

    assert query_key_log_lines(log) == []
  end

  test "MCP logs a legacy key's use, never the key; the admin key logs nothing" do
    pattern = ~r/A request on \S+ authenticated with the legacy GUARDIAN_API_KEY/

    log =
      capture_auth_note_log(fn ->
        assert request("/mcp", "", [@admin_api_key]).status == 405
        assert request("/mcp", "", [@api_key]).status == 405
      end)

    assert Regex.scan(pattern, log) ==
             [["A request on /mcp authenticated with the legacy GUARDIAN_API_KEY"]]

    refute log =~ @api_key

    log =
      capture_auth_note_log(fn ->
        assert request("/mcp", "", [@admin_api_key]).status == 405
      end)

    assert Regex.scan(pattern, log) == []
  end

  test "MCP logs both notes for a legacy key in the query parameter" do
    log =
      capture_auth_note_log(fn ->
        with_query_api_keys(true, fn ->
          assert request("/mcp", "api_key=#{@api_key}", []).status == 405
        end)
      end)

    assert query_key_log_lines(log) == [
             "A request on /mcp authenticated with the api_key query parameter",
           ]

    assert log =~ "A request on /mcp authenticated with the legacy GUARDIAN_API_KEY"
    refute log =~ @api_key
  end

  test "an ingest key naming a session is forbidden before the session check" do
    conn = Plug.Test.conn(:post, "https://localhost/mcp", "{}")

    conn = %{
      conn
      | req_headers: [
          {"x-api-key", @ingest_api_key},
          {"mcp-session-id", "any"} | conn.req_headers,
        ],
    }

    conn = Guardian.Web.MainRouter.call(conn, nil)
    assert {conn.status, conn.resp_body} == {403, @mcp_forbidden}
  end

  test "with query keys refused, MCP answers 401 whatever the query string" do
    nested = "x" <> String.duplicate("[a]", 40) <> "=1"

    with_query_api_keys(false, fn ->
      for query <- ["x=%FF", nested, "api_key=%E0%A4%A"] do
        conn = request("/mcp", query, [])
        assert {conn.status, conn.resp_body} == {401, @mcp_missing}
      end
    end)
  end

  test "the MCP endpoint answers an undecodable query string with a JSON error" do
    with_query_api_keys(true, &mcp_undecodable_query_cases/0)
  end

  defp mcp_undecodable_query_cases do
    nested = "x" <> String.duplicate("[a]", 40) <> "=1"
    long = "x=" <> String.duplicate("a", 1_000_000)

    # No header: the key check decodes the query string to look for api_key.
    for {query, status} <- [{"x=%FF", 400}, {nested, 400}, {long, 414}] do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          conn = request("/mcp", query, [])
          assert conn.halted
          assert {conn.status, conn.resp_body} == {status, ~s({"error":"invalid query string"})}

          assert Plug.Conn.get_resp_header(conn, "content-type") ==
                   ["application/json; charset=utf-8"]
        end)

      assert output == ""
    end

    # A key header: nothing decodes the query string, so it is judged by the key alone.
    assert request("/mcp", "x=%FF", [@api_key]).status == 405

    conn = request("/mcp", "x=%FF", ["wrong"])
    assert {conn.status, conn.resp_body} == {401, @mcp_unauthorized}
  end
end

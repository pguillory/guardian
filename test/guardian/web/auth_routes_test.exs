defmodule Guardian.Web.AuthRoutesTest do
  # Each well-formed credential form against both authenticated routers, with the
  # exact 401 and 403 responses, so how a key is accepted cannot drift between them.
  # Both requests need full access (a JSON path other than POST /send_events, and
  # /mcp), so the ingest key is forbidden on both.
  # A key in the URL counts as no key at all. One test changes the configured keys, so
  # this module is not async.
  use ExUnit.Case, async: false

  @admin_api_key Application.compile_env!(:guardian, :admin_api_key)
  @ingest_api_key Application.compile_env!(:guardian, :ingest_api_key)

  @json_missing ~s({"info":"api_key required","status":401}\n)
  @json_unauthorized ~s({"info":"unauthorized","status":401}\n)
  @mcp_missing ~s({"error":"api_key required"})
  @mcp_unauthorized ~s({"error":"unauthorized"})
  @json_forbidden ~s({"info":"this key can only send events","status":403}\n)
  @mcp_forbidden ~s({"error":"this key can only send events"})

  # {description, query string, x-api-key headers in order, expected outcome}.
  defp cases do
    [
      {"no key", "", [], :missing},
      {"an empty header", "", [""], :unauthorized},
      {"a wrong header", "", ["wrong"], :unauthorized},
      {"a valid admin header", "", [@admin_api_key], :ok},
      {"a valid ingest header", "", [@ingest_api_key], :forbidden},
      {"a valid ingest query parameter", "api_key=#{@ingest_api_key}", [], :missing},
      {"a valid admin query parameter", "api_key=#{@admin_api_key}", [], :missing},
      {"a wrong query parameter", "api_key=wrong", [], :missing},
      {"an empty query parameter", "api_key=", [], :missing},
      {"a wrong header over a valid query parameter", "api_key=#{@admin_api_key}", ["wrong"],
       :unauthorized},
      {"a valid header over a wrong query parameter", "api_key=wrong", [@admin_api_key], :ok},
      {"a wrong first header before a valid one", "", ["wrong", @admin_api_key], :unauthorized},
      {"a valid first header before a wrong one", "", [@admin_api_key, "wrong"], :ok},
      {"an ingest header before an admin one", "", [@ingest_api_key, @admin_api_key], :forbidden},
      {"a list-shaped query parameter", "api_key[]=#{@admin_api_key}", [], :missing},
      {"a map-shaped query parameter", "api_key[a]=#{@admin_api_key}", [], :missing},
      {"another query parameter only", "key=#{@admin_api_key}", [], :missing},
    ]
  end

  defp request(path, query, keys) do
    url = if query == "", do: path, else: path <> "?" <> query
    conn = Plug.Test.conn(:get, "https://localhost" <> url)
    headers = Enum.map(keys, &{"x-api-key", &1})
    Guardian.Web.MainRouter.call(%{conn | req_headers: headers ++ conn.req_headers}, nil)
  end

  test "the JSON API accepts and rejects each credential form" do
    for {description, query, keys, expected} <- cases() do
      conn = request("/api/json/wrong", query, keys)

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
    for {description, query, keys, expected} <- cases() do
      conn = request("/mcp", query, keys)

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

  test "the removed GUARDIAN_API_KEY's application setting is refused like a wrong key" do
    former_key = "guardian_test_former_api_key"

    Guardian.Test.Env.with_env([api_key: former_key], fn ->
      conn = request("/api/json/wrong", "", [former_key])
      assert {conn.status, conn.resp_body} == {401, @json_unauthorized}

      conn = request("/mcp", "", [former_key])
      assert {conn.status, conn.resp_body} == {401, @mcp_unauthorized}
    end)
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

  test "MCP answers 401 whatever the query string, without decoding it" do
    nested = "x" <> String.duplicate("[a]", 40) <> "=1"
    long = "x=" <> String.duplicate("a", 1_000_000)

    for query <- ["x=%FF", nested, long, "api_key=%E0%A4%A"] do
      conn = request("/mcp", query, [])
      assert {conn.status, conn.resp_body} == {401, @mcp_missing}
    end

    # With a key header the query string is still not decoded: judged by the key alone.
    assert request("/mcp", "x=%FF", [@admin_api_key]).status == 405

    conn = request("/mcp", "x=%FF", ["wrong"])
    assert {conn.status, conn.resp_body} == {401, @mcp_unauthorized}
  end
end

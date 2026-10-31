defmodule Guardian.Web.AuthSettingsTest do
  # Not async: puts the API key settings in the application env, which the key check
  # reads instead of taking them as arguments.
  use ExUnit.Case, async: false
  import Guardian.Web.Auth

  @admin_api_key Application.compile_env!(:guardian, :admin_api_key)
  @ingest_api_key Application.compile_env!(:guardian, :ingest_api_key)

  @json_unauthorized ~s({"info":"unauthorized","status":401}\n)
  @mcp_unauthorized ~s({"error":"unauthorized"})

  defp conn(query, keys) do
    conn = Plug.Test.conn(:get, "/?" <> query)
    %{conn | req_headers: Enum.map(keys, &{"x-api-key", &1}) ++ conn.req_headers}
  end

  defp request(path, query, keys) do
    url = if query == "", do: path, else: path <> "?" <> query
    conn = Plug.Test.conn(:get, "https://localhost" <> url)
    headers = Enum.map(keys, &{"x-api-key", &1})
    Guardian.Web.MainRouter.call(%{conn | req_headers: headers ++ conn.req_headers}, nil)
  end

  test "an unset key matches nothing" do
    Guardian.Test.Env.with_env([ingest_api_key: nil], fn ->
      assert identify_api_key(@ingest_api_key) == {:error, :unauthorized}
      assert identify_api_key(@admin_api_key) == {:ok, :admin}
    end)
  end

  test "the removed GUARDIAN_API_KEY's application setting grants nothing" do
    former_key = "guardian_test_former_api_key"

    Guardian.Test.Env.with_env([api_key: former_key], fn ->
      assert identify_api_key(former_key) == {:error, :unauthorized}
      assert check_conn(conn("", [former_key]), :ingest) == {:error, :unauthorized}
    end)
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
end

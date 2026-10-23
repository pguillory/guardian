defmodule Web.AuthTest do
  # async: false: some tests switch query-parameter keys on.
  use ExUnit.Case, async: false

  alias Web.Auth

  @api_key Application.compile_env!(:guardian, :api_key)

  test "a valid API key authorizes without attaching an identity" do
    assert Auth.authorize_api_key(@api_key) == :ok
    assert Auth.authorize_api_key("wrong") == {:error, :unauthorized}
    assert Auth.authorize_api_key("") == {:error, :unauthorized}
    assert Auth.authorize_api_key([@api_key]) == {:error, :unauthorized}
    assert Auth.authorize_api_key(%{"a" => @api_key}) == {:error, :unauthorized}
  end

  defp conn(query, keys) do
    conn = Plug.Test.conn(:get, "/?" <> query)
    %{conn | req_headers: Enum.map(keys, &{"x-api-key", &1}) ++ conn.req_headers}
  end

  describe "check_conn/1 with query keys allowed" do
    setup do
      Application.put_env(:guardian, :allow_query_api_key, true)
      on_exit(fn -> Application.delete_env(:guardian, :allow_query_api_key) end)
    end

    test "takes the first x-api-key header, else the api_key query parameter" do
      assert Auth.check_conn(conn("", [@api_key])) == {:ok, :header}
      assert Auth.check_conn(conn("api_key=#{@api_key}", [])) == {:ok, :query}
      assert Auth.check_conn(conn("api_key=wrong", [@api_key])) == {:ok, :header}
      assert Auth.check_conn(conn("api_key=#{@api_key}", ["wrong"])) == {:error, :unauthorized}
      assert Auth.check_conn(conn("", [@api_key, "wrong"])) == {:ok, :header}
      assert Auth.check_conn(conn("", ["wrong", @api_key])) == {:error, :unauthorized}
    end

    test "tells a missing key from a wrong one" do
      assert Auth.check_conn(conn("", [])) == {:error, :missing}
      assert Auth.check_conn(conn("other=1", [])) == {:error, :missing}
      assert Auth.check_conn(conn("", [""])) == {:error, :unauthorized}
      assert Auth.check_conn(conn("api_key=", [])) == {:error, :unauthorized}
      assert Auth.check_conn(conn("api_key[]=#{@api_key}", [])) == {:error, :unauthorized}
      assert Auth.check_conn(conn("api_key[a]=#{@api_key}", [])) == {:error, :unauthorized}
    end

    test "decodes the query string only when there is no header" do
      malformed = conn("api_key=%E0%A4%A", [])

      assert Auth.check_conn(%{malformed | req_headers: [{"x-api-key", @api_key}]}) ==
               {:ok, :header}

      assert Auth.check_conn(malformed) == {:error, {:invalid_query, 400}}
      long = conn("x=" <> String.duplicate("a", 1_000_000), [])
      assert Auth.check_conn(long) == {:error, {:invalid_query, 414}}
    end
  end

  describe "check_conn/1 with query keys refused (the default)" do
    test "accepts only the first x-api-key header" do
      refute Auth.query_api_key_allowed?()
      assert Auth.check_conn(conn("", [@api_key])) == {:ok, :header}
      assert Auth.check_conn(conn("api_key=wrong", [@api_key])) == {:ok, :header}
      assert Auth.check_conn(conn("", ["wrong", @api_key])) == {:error, :unauthorized}
      assert Auth.check_conn(conn("api_key=#{@api_key}", [])) == {:error, :missing}
      assert Auth.check_conn(conn("api_key=#{@api_key}", ["wrong"])) == {:error, :unauthorized}
    end

    test "never decodes the query string" do
      assert Auth.check_conn(conn("api_key=%E0%A4%A", [])) == {:error, :missing}
      long = conn("x=" <> String.duplicate("a", 1_000_000), [])
      assert Auth.check_conn(long) == {:error, :missing}
    end
  end

  test "note_query_key_use/1 logs the path at most once a minute, never a key" do
    log =
      QueryApiKeys.capture_query_key_log(fn ->
        Auth.note_query_key_use("/mcp")
        Auth.note_query_key_use("/mcp")
      end)

    assert QueryApiKeys.query_key_log_lines(log) == [
             "A request on /mcp authenticated with the api_key query parameter",
           ]

    refute log =~ @api_key
  end
end

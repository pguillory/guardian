defmodule Guardian.Web.AuthTest do
  # async: false: some tests switch query-parameter keys on.
  use ExUnit.Case, async: false

  alias Guardian.Web.Auth

  @api_key Application.compile_env!(:guardian, :api_key)
  @admin_api_key Application.compile_env!(:guardian, :admin_api_key)
  @ingest_api_key Application.compile_env!(:guardian, :ingest_api_key)

  test "identify_api_key/1 names the matching key without attaching an identity" do
    assert Auth.identify_api_key(@api_key) == {:ok, :legacy}
    assert Auth.identify_api_key(@admin_api_key) == {:ok, :admin}
    assert Auth.identify_api_key(@ingest_api_key) == {:ok, :ingest}
    assert Auth.identify_api_key("wrong") == {:error, :unauthorized}
    assert Auth.identify_api_key("") == {:error, :unauthorized}
    assert Auth.identify_api_key(@api_key <> "x") == {:error, :unauthorized}
    assert Auth.identify_api_key([@api_key]) == {:error, :unauthorized}
    assert Auth.identify_api_key(%{"a" => @api_key}) == {:error, :unauthorized}
  end

  test "an unset key matches nothing" do
    Guardian.Test.Env.with_env([api_key: nil, ingest_api_key: nil], fn ->
      assert Auth.identify_api_key(@api_key) == {:error, :unauthorized}
      assert Auth.identify_api_key(@ingest_api_key) == {:error, :unauthorized}
      assert Auth.identify_api_key(@admin_api_key) == {:ok, :admin}
    end)
  end

  test "check_conn/2 grants ingestion to every key and full access to admin and legacy" do
    for {key, name} <- [{@api_key, :legacy}, {@admin_api_key, :admin}] do
      assert Auth.check_conn(conn("", [key]), :ingest) == {:ok, :header, name}
      assert Auth.check_conn(conn("", [key]), :full) == {:ok, :header, name}
    end

    assert Auth.check_conn(conn("", [@ingest_api_key]), :ingest) == {:ok, :header, :ingest}
    assert Auth.check_conn(conn("", [@ingest_api_key]), :full) == {:error, :forbidden}
    assert Auth.check_conn(conn("", ["wrong"]), :ingest) == {:error, :unauthorized}
    assert Auth.check_conn(conn("", []), :ingest) == {:error, :missing}
  end

  defp conn(query, keys) do
    conn = Plug.Test.conn(:get, "/?" <> query)
    %{conn | req_headers: Enum.map(keys, &{"x-api-key", &1}) ++ conn.req_headers}
  end

  describe "check_conn/2 with query keys allowed" do
    setup do
      Guardian.Test.Env.put(allow_query_api_key: true)
      :ok
    end

    test "takes the first x-api-key header, else the api_key query parameter" do
      assert Auth.check_conn(conn("", [@api_key]), :full) == {:ok, :header, :legacy}
      assert Auth.check_conn(conn("api_key=#{@api_key}", []), :full) == {:ok, :query, :legacy}
      assert Auth.check_conn(conn("api_key=wrong", [@api_key]), :full) == {:ok, :header, :legacy}

      assert Auth.check_conn(conn("api_key=#{@api_key}", ["wrong"]), :full) ==
               {:error, :unauthorized}

      assert Auth.check_conn(conn("", [@api_key, "wrong"]), :full) == {:ok, :header, :legacy}
      assert Auth.check_conn(conn("", ["wrong", @api_key]), :full) == {:error, :unauthorized}
    end

    test "tells a missing key from a wrong one" do
      assert Auth.check_conn(conn("", []), :full) == {:error, :missing}
      assert Auth.check_conn(conn("other=1", []), :full) == {:error, :missing}
      assert Auth.check_conn(conn("", [""]), :full) == {:error, :unauthorized}
      assert Auth.check_conn(conn("api_key=", []), :full) == {:error, :unauthorized}
      assert Auth.check_conn(conn("api_key[]=#{@api_key}", []), :full) == {:error, :unauthorized}
      assert Auth.check_conn(conn("api_key[a]=#{@api_key}", []), :full) == {:error, :unauthorized}
    end

    test "decodes the query string only when there is no header" do
      malformed = conn("api_key=%E0%A4%A", [])

      assert Auth.check_conn(%{malformed | req_headers: [{"x-api-key", @api_key}]}, :full) ==
               {:ok, :header, :legacy}

      assert Auth.check_conn(malformed, :full) == {:error, {:invalid_query, 400}}
      long = conn("x=" <> String.duplicate("a", 1_000_000), [])
      assert Auth.check_conn(long, :full) == {:error, {:invalid_query, 414}}
    end
  end

  describe "check_conn/2 with query keys refused (the default)" do
    test "accepts only the first x-api-key header" do
      refute Auth.query_api_key_allowed?()
      assert Auth.check_conn(conn("", [@api_key]), :full) == {:ok, :header, :legacy}
      assert Auth.check_conn(conn("api_key=wrong", [@api_key]), :full) == {:ok, :header, :legacy}
      assert Auth.check_conn(conn("", ["wrong", @api_key]), :full) == {:error, :unauthorized}
      assert Auth.check_conn(conn("api_key=#{@api_key}", []), :full) == {:error, :missing}

      assert Auth.check_conn(conn("api_key=#{@api_key}", ["wrong"]), :full) ==
               {:error, :unauthorized}
    end

    test "never decodes the query string" do
      assert Auth.check_conn(conn("api_key=%E0%A4%A", []), :full) == {:error, :missing}
      long = conn("x=" <> String.duplicate("a", 1_000_000), [])
      assert Auth.check_conn(long, :full) == {:error, :missing}
    end
  end

  test "note_query_key_use/1 logs the path at most once a minute, never a key" do
    log =
      Guardian.Test.QueryApiKeys.capture_auth_note_log(fn ->
        Auth.note_query_key_use("/mcp")
        Auth.note_query_key_use("/mcp")
      end)

    assert Guardian.Test.QueryApiKeys.query_key_log_lines(log) == [
             "A request on /mcp authenticated with the api_key query parameter",
           ]

    refute log =~ @api_key
  end

  test "note_legacy_key_use/1 logs the path at most once a minute, apart from query keys" do
    log =
      Guardian.Test.QueryApiKeys.capture_auth_note_log(fn ->
        Auth.note_query_key_use("/mcp")
        Auth.note_legacy_key_use("/mcp")
        Auth.note_legacy_key_use("/mcp")
      end)

    assert Regex.scan(~r/A request on \S+ authenticated with the legacy GUARDIAN_API_KEY/, log) ==
             [["A request on /mcp authenticated with the legacy GUARDIAN_API_KEY"]]

    assert Guardian.Test.QueryApiKeys.query_key_log_lines(log) == [
             "A request on /mcp authenticated with the api_key query parameter",
           ]

    refute log =~ @api_key
  end
end

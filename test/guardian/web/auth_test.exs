defmodule Guardian.Web.AuthTest do
  # async: false: tests change the configured keys.
  use ExUnit.Case, async: false

  alias Guardian.Web.Auth

  @admin_api_key Application.compile_env!(:guardian, :admin_api_key)
  @ingest_api_key Application.compile_env!(:guardian, :ingest_api_key)

  test "identify_api_key/1 names the matching key without attaching an identity" do
    assert Auth.identify_api_key(@admin_api_key) == {:ok, :admin}
    assert Auth.identify_api_key(@ingest_api_key) == {:ok, :ingest}
    assert Auth.identify_api_key("wrong") == {:error, :unauthorized}
    assert Auth.identify_api_key("") == {:error, :unauthorized}
    assert Auth.identify_api_key(@admin_api_key <> "x") == {:error, :unauthorized}
    assert Auth.identify_api_key([@admin_api_key]) == {:error, :unauthorized}
    assert Auth.identify_api_key(%{"a" => @admin_api_key}) == {:error, :unauthorized}
  end

  test "an unset key matches nothing" do
    Guardian.Test.Env.with_env([ingest_api_key: nil], fn ->
      assert Auth.identify_api_key(@ingest_api_key) == {:error, :unauthorized}
      assert Auth.identify_api_key(@admin_api_key) == {:ok, :admin}
    end)
  end

  test "the removed GUARDIAN_API_KEY's application setting grants nothing" do
    former_key = "guardian_test_former_api_key"

    Guardian.Test.Env.with_env([api_key: former_key], fn ->
      assert Auth.identify_api_key(former_key) == {:error, :unauthorized}
      assert Auth.check_conn(conn("", [former_key]), :ingest) == {:error, :unauthorized}
    end)
  end

  test "check_conn/2 grants ingestion to both keys and full access to the admin key" do
    assert Auth.check_conn(conn("", [@admin_api_key]), :ingest) == {:ok, :admin}
    assert Auth.check_conn(conn("", [@admin_api_key]), :full) == {:ok, :admin}
    assert Auth.check_conn(conn("", [@ingest_api_key]), :ingest) == {:ok, :ingest}
    assert Auth.check_conn(conn("", [@ingest_api_key]), :full) == {:error, :forbidden}
    assert Auth.check_conn(conn("", ["wrong"]), :ingest) == {:error, :unauthorized}
    assert Auth.check_conn(conn("", []), :ingest) == {:error, :missing}
  end

  defp conn(query, keys) do
    conn = Plug.Test.conn(:get, "/?" <> query)
    %{conn | req_headers: Enum.map(keys, &{"x-api-key", &1}) ++ conn.req_headers}
  end

  describe "check_conn/2" do
    test "accepts only the first x-api-key header" do
      key = @admin_api_key
      assert Auth.check_conn(conn("", [key]), :full) == {:ok, :admin}
      assert Auth.check_conn(conn("api_key=wrong", [key]), :full) == {:ok, :admin}
      assert Auth.check_conn(conn("", [key, "wrong"]), :full) == {:ok, :admin}
      assert Auth.check_conn(conn("", ["wrong", key]), :full) == {:error, :unauthorized}
      assert Auth.check_conn(conn("", [""]), :full) == {:error, :unauthorized}

      assert Auth.check_conn(conn("api_key=#{key}", ["wrong"]), :full) ==
               {:error, :unauthorized}
    end

    test "never accepts a key in the URL" do
      for key <- [@admin_api_key, @ingest_api_key] do
        assert Auth.check_conn(conn("api_key=#{key}", []), :ingest) == {:error, :missing}
      end
    end

    test "never decodes the query string" do
      assert Auth.check_conn(conn("api_key=%E0%A4%A", []), :full) == {:error, :missing}
      long = conn("x=" <> String.duplicate("a", 1_000_000), [])
      assert Auth.check_conn(long, :full) == {:error, :missing}
    end
  end
end

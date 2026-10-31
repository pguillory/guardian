defmodule Guardian.ObjectStore.S3Test do
  use ExUnit.Case, async: true
  import Guardian.ObjectStore.S3

  test "endpoint and prefix checks" do
    assert check_endpoint("https://example.com") == :ok
    assert check_endpoint("http://localhost:9000") == :ok
    assert check_endpoint("http://127.0.0.5") == :ok
    assert check_endpoint("http://[::1]:9000") == :ok
    assert check_endpoint("http://example.com") == {:error, :insecure}
    assert check_endpoint("https://example.com/path") == {:error, :not_url}
    assert check_endpoint("ftp://example.com") == {:error, :not_url}
    assert check_prefix("") == :ok
    assert check_prefix("a/b/") == :ok
    assert check_prefix("a") == {:error, :no_trailing_slash}
    assert check_prefix("a b/") == {:error, :invalid_characters}
  end
end

defmodule Guardian.Config.ConfigTest do
  use ExUnit.Case, async: true

  @config Path.expand("../../../config/config.exs", __DIR__)

  defp read(env) do
    Config.Reader.read!(@config, env: env, target: :host)
  end

  # At debug, Anubis logs a line for every MCP message and session event to the server
  # log, which on Fly is outside Guardian's retention.
  test "production never logs at debug" do
    level = read(:prod) |> Keyword.get(:logger, []) |> Keyword.get(:level)
    assert level == :info
  end

  test "tests log warnings and use the test keys" do
    config = read(:test)
    assert config[:logger][:level] == :warning
    refute Keyword.has_key?(config[:guardian], :api_key)
    assert config[:guardian][:admin_api_key] == "guardian_test_admin_api_key"
    assert config[:guardian][:ingest_api_key] == "guardian_test_ingest_api_key"
  end

  test "there is no environment config file that config.exs would silently skip" do
    assert Path.wildcard(Path.join(Path.dirname(@config), "*.exs"))
           |> Enum.map(&Path.basename/1)
           |> Enum.sort() == ["config.exs", "runtime.exs"]
  end
end

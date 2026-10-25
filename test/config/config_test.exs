defmodule Guardian.ConfigTest do
  use ExUnit.Case, async: true

  @config Path.expand("../../config/config.exs", __DIR__)

  defp read(env), do: Config.Reader.read!(@config, env: env, target: :host)

  # At debug, Anubis logs every MCP message (query SQL, send_events payloads) to the
  # server log, which on Fly is outside Guardian's retention.
  test "production never logs at debug" do
    level = read(:prod) |> Keyword.get(:logger, []) |> Keyword.get(:level)
    assert level == :info
  end

  test "tests log warnings and use the test key" do
    config = read(:test)
    assert config[:logger][:level] == :warning
    assert config[:guardian][:api_key] == "guardian_test_api_key"
  end

  test "there is no environment config file that config.exs would silently skip" do
    assert Path.wildcard(Path.join(Path.dirname(@config), "*.exs"))
           |> Enum.map(&Path.basename/1)
           |> Enum.sort() == ["config.exs", "runtime.exs"]
  end
end

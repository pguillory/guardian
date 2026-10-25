import Config

config :elixir,
  ansi_enabled: true

# Production reads GUARDIAN_DATA_DIR in runtime.exs; these paths are only for Mix runs.
if config_env() == :dev do
  config :guardian, data_dir: Path.join([File.cwd!(), "data", "dev"])
end

if config_env() == :test do
  # Each test run gets a fresh data directory, removed when the run's VM exits
  # (test/test_helper.exs). Tests name tables with System.unique_integer, which restarts
  # every run, so a directory shared across runs would hand a new run tables that an
  # earlier run left on disk.
  config :guardian,
    data_dir:
      Path.join(
        System.tmp_dir!(),
        "guardian-test-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

  config :guardian, api_key: "guardian_test_api_key"

  # Internal compile-time test seam, not an operator setting. Releases call Store directly.
  config :guardian, Guardian.Counters.Transport, store_backend: Guardian.CounterTestBackend

  # Many tests send malformed queries; the hourly cap has its own test.
  config :guardian, query_parse_errors_per_hour: 1_000_000

  config :logger, level: :warning
end

# Production logs at info. At debug, Anubis (the MCP library) logs every MCP message,
# so query SQL and send_events payloads would reach Fly's log stream. This file is
# compiled into the release; config/runtime.exs is the only other config file.
if config_env() == :prod do
  config :logger, level: :info
end

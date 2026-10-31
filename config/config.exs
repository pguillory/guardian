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

  # The two API keys (Guardian.Web.Auth): the full-access admin key and the
  # insert-only ingest key.
  config :guardian,
    admin_api_key: "guardian_test_admin_api_key",
    ingest_api_key: "guardian_test_ingest_api_key"

  # Internal compile-time test seam, not an operator setting. Releases call Store directly.
  config :guardian, Guardian.Counters.Transport, store_backend: Guardian.Test.Counters.Backend

  # Same kind of seam: a slow healthy call under host load must not silently give a
  # default count, and this stays under Runner's 1 s row limit. Releases use 50 ms.
  config :guardian, Guardian.Counters.Context, call_timeout_ms: 500

  # Same kind of seam: lets a test make the query path exit or throw, which nothing a
  # query can do reaches. Releases call Guardian.Query directly.
  config :guardian, Guardian.Web.Query, query_backend: Guardian.Test.Web.QueryBackend

  # Many tests send malformed queries; keep them under the hourly cap.
  config :guardian, query_parse_errors_per_hour: 1_000_000

  config :logger, level: :warning
end

# Production logs at info. At debug, Anubis (the MCP library) logs a line for every MCP
# message and session event (methods, request IDs, session IDs, client info; before 2.x, whole
# messages with their SQL and events), which should not reach Fly's log stream. This file is
# compiled into the release; config/runtime.exs is the only other config file.
if config_env() == :prod do
  config :logger, level: :info
end

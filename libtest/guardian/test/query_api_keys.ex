defmodule Guardian.Test.QueryApiKeys do
  @moduledoc """
  Runs a test body with the `api_key` query parameter allowed or refused
  (`:guardian, :allow_query_api_key`), restoring the setting afterwards. The setting is
  global, so only `async: false` tests may use it.
  """

  @doc """
  Runs `fun` with Logger at info and every `Guardian.Web.Auth` once-a-minute note (the
  query-parameter key and the legacy key) reset, and returns what was logged.
  """
  def capture_auth_note_log(fun) do
    previous_level = Logger.level()

    for reason <- [:query_key, :legacy_key] do
      :persistent_term.erase({Guardian.Web.Auth, :noted_at, reason})
    end

    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  @doc "The query-key lines in a captured log, without timestamps and levels."
  def query_key_log_lines(log) do
    Regex.scan(~r/A request on \S+ authenticated with the api_key query parameter/, log)
    |> List.flatten()
  end

  @doc "Runs `fun` with the `api_key` query parameter allowed or refused."
  def with_query_api_keys(allowed?, fun) when is_boolean(allowed?) do
    Guardian.Test.Env.with_env([allow_query_api_key: allowed?], fun)
  end
end

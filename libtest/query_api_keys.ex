defmodule Guardian.QueryApiKeys do
  @moduledoc """
  Runs a test body with the `api_key` query parameter allowed or refused
  (`:guardian, :allow_query_api_key`), restoring the setting afterwards. The setting is
  global, so only `async: false` tests may use it.
  """

  @doc """
  Runs `fun` with Logger at info and `Guardian.Web.Auth`'s once-a-minute query-key log reset,
  and returns what was logged.
  """
  def capture_query_key_log(fun) do
    previous_level = Logger.level()
    :persistent_term.erase({Guardian.Web.Auth, :query_key_logged_at})
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

  def with_query_api_keys(allowed?, fun) when is_boolean(allowed?) do
    previous = Application.fetch_env(:guardian, :allow_query_api_key)
    Application.put_env(:guardian, :allow_query_api_key, allowed?)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:guardian, :allow_query_api_key, value)
        :error -> Application.delete_env(:guardian, :allow_query_api_key)
      end
    end
  end
end

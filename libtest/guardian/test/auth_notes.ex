defmodule Guardian.Test.AuthNotes do
  @moduledoc """
  Captures `Guardian.Web.Auth`'s once-a-minute log notes. Changes the global Logger
  level, so only `async: false` tests may use it.
  """

  @doc """
  Runs `fun` with Logger at info and every `Guardian.Web.Auth` once-a-minute note
  reset, and returns what was logged.
  """
  def capture_auth_note_log(fun) do
    previous_level = Logger.level()
    :persistent_term.erase({Guardian.Web.Auth, :noted_at, :legacy_key})
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end
end

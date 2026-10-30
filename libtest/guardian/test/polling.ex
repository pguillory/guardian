defmodule Guardian.Test.Polling do
  @moduledoc """
  Polls until test conditions hold. The one polling helper for tests; do not write a
  local retry loop. Callers must isolate the state they observe.
  """

  import ExUnit.Assertions

  @doc """
  Calls `fun` every `interval_ms` (default 10) until it returns a truthy value, and fails
  the test if none does within `timeout_ms`. Returns `:ok`. `fun` must return a
  boolean-like value: an empty list is truthy here, so poll for a list with `value/2`.
  """
  def eventually(fun, timeout_ms \\ 5_000, interval_ms \\ 10) do
    value(fn -> if fun.(), do: :ok end, timeout_ms, interval_ms)
  end

  @doc """
  Like `eventually/3`, but returns the first result of `fun` that is not `nil`, `false`
  or `[]`, so a poll for a nonempty list or a found value hands it back.
  """
  def value(fun, timeout_ms \\ 5_000, interval_ms \\ 10) do
    poll(fun, System.monotonic_time(:millisecond) + timeout_ms, interval_ms)
  end

  @doc """
  Runs `fun`, which makes assertions, until it stops raising `ExUnit.AssertionError`,
  for up to `timeout_ms`. The last attempt runs outside the retry, so a failure reports
  the real assertion.
  """
  def assert_eventually(fun, timeout_ms \\ 5_000, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    retry_assertion(fun, deadline, interval_ms)
  end

  defp poll(fun, deadline, interval_ms) do
    case fun.() do
      result when result in [nil, false, []] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition never held")
        else
          Process.sleep(interval_ms)
          poll(fun, deadline, interval_ms)
        end

      result ->
        result
    end
  end

  defp retry_assertion(fun, deadline, interval_ms) do
    if System.monotonic_time(:millisecond) > deadline do
      fun.()
    else
      try do
        fun.()
      rescue
        ExUnit.AssertionError ->
          Process.sleep(interval_ms)
          retry_assertion(fun, deadline, interval_ms)
      end
    end
  end
end

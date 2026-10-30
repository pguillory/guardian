defmodule Guardian.Test.Polling do
  @moduledoc """
  Polls until test conditions hold. Callers must isolate the state they observe.
  """

  import ExUnit.Assertions

  @doc """
  Calls `fun` every 10 ms until it returns a truthy value, and fails the test if none
  does within `timeout_ms`. Returns `:ok`. `fun` must return a boolean-like value:
  an empty list is truthy here, so poll for a list with an explicit predicate.
  """
  def eventually(fun, timeout_ms \\ 5_000) do
    poll(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never held")

      true ->
        Process.sleep(10)
        poll(fun, deadline)
    end
  end
end

defmodule Guardian.Test.Polling do
  @moduledoc """
  Polls until test conditions hold. Callers must isolate the state they observe.
  `eventually_after_gc/1` requests garbage collection in every process in the VM;
  tests observing global resource counts must run with `async: false`.
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

  @doc """
  Like `eventually/2` for a condition that waits on garbage collection, such as a
  released NIF resource: before each check it collects garbage in every process. It
  checks 51 times, 20 ms apart, and fails the test if the condition never holds.
  """
  def eventually_after_gc(fun) do
    poll_after_gc(fun, 50)
  end

  defp poll_after_gc(fun, attempts) do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)

    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(20)
        poll_after_gc(fun, attempts - 1)
    end
  end
end

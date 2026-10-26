defmodule Guardian.Counters.Clock do
  @moduledoc """
  The local monotonic microsecond coordinate shared by Counters Context, Budget and
  Transport.

  Context's event deadline and operation timeout, Budget's reservations, settlement
  timestamps and cooldowns, and Transport's dispatch deadlines (`started + reserved`)
  are all instants or durations in this node's `System.monotonic_time(:microsecond)`.
  Never send an instant to another node: remote endpoints receive a remaining duration
  in milliseconds and anchor it with `deadline/1` on their own clock. Store's
  `:deadline` option is a monotonic millisecond instant (`to_store_ms/1`).

  Mutation TTLs are a separate contract: their expiries use the event's monotonic
  arrival coordinate (`Guardian.Counters.Arrival`,
  `System.monotonic_time(:millisecond)`), not this one.
  """

  @doc "The current local monotonic instant, in microseconds."
  @spec now() :: integer()
  def now do
    System.monotonic_time(:microsecond)
  end

  @doc "A duration in milliseconds, as microseconds."
  @spec from_ms(integer()) :: integer()
  def from_ms(ms) do
    ms * 1_000
  end

  @doc "The instant `ms` milliseconds from now."
  @spec deadline(integer()) :: integer()
  def deadline(ms) do
    now() + from_ms(ms)
  end

  @doc "Whole milliseconds left before `deadline`, truncated and never negative."
  @spec remaining_ms(integer()) :: non_neg_integer()
  def remaining_ms(deadline) do
    max(0, div(deadline - now(), 1_000))
  end

  @doc """
  `deadline` as a monotonic millisecond instant, comparable with
  `System.monotonic_time(:millisecond)` as Store's `:deadline` option requires. Floors,
  so negative instants round down too.
  """
  @spec to_store_ms(integer()) :: integer()
  def to_store_ms(deadline) do
    Integer.floor_div(deadline, 1_000)
  end
end

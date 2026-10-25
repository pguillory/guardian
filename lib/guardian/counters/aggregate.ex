defmodule Guardian.Counters.Aggregate do
  @moduledoc """
  Counter API adapter for the shared `Guardian.Aggregation` implementations.

  Operators are explicitly opted-in `{name, arity}` tuples from the registry.
  `create/2` accepts one event's storage-safe argument values. `default/1` is an
  empty mergeable state, not the query registry's already resolved empty result.
  Merge bucket states before resolving once, including native count increments.
  Compare states with `===` to skip unchanged writes.

  The registry preserves counter policies: precision-8 bitstring distinct sketches,
  int64 count output bounds and exact average empty identities. Query policies and
  the existing counter state representations remain unchanged. This module performs
  no aggregate arithmetic or storage operations.
  """

  alias Guardian.Aggregation

  @type operator :: {String.t(), non_neg_integer()}

  @doc "The supported operator names and exact arities."
  @spec operators() :: [operator()]
  def operators do
    Aggregation.counter_operators()
  end

  @doc "An empty mergeable state, rather than an already resolved result."
  @spec default(operator()) :: term()
  def default(operator) do
    operator |> Aggregation.fetch_counter!() |> Aggregation.empty()
  end

  @doc "A state from one event's argument values; null inputs are skipped."
  @spec create(operator(), [term()]) :: term()
  def create({_name, arity} = operator, values)
      when is_list(values) and length(values) == arity do
    operator |> Aggregation.fetch_counter!() |> Aggregation.start(values)
  end

  def create(_operator, _values) do
    raise ArgumentError, "unsupported counter aggregate or arity"
  end

  @doc "Combines states for the same operator; the empty state is an identity."
  @spec merge(operator(), term(), term()) :: term()
  def merge(operator, left, right) do
    operator |> Aggregation.fetch_counter!() |> Aggregation.merge(left, right)
  end

  @doc "Resolves a merged window state to its storage-safe result."
  @spec resolve(operator(), term()) :: term()
  def resolve(operator, state) do
    operator |> Aggregation.fetch_counter!() |> Aggregation.finish(state)
  end
end

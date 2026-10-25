defmodule Guardian.Counters.Aggregate do
  @moduledoc """
  Pure, mergeable states for counter buckets, independent of query execution.

  Operators are fixed `{name, arity}` tuples from `operators/0`. `create/2` takes
  one event's argument values, not a batch. Inputs are storage-safe scalar
  expression results, and states must belong to the same operator.

  `default/1` always returns an empty state. Resolve it for a missing result: zero
  for count and distinct count, null for the others. In particular, counter sum's
  empty result differs from the query aggregate's empty result of 0.0.

  Merge bucket states before resolving once. Count states, including values from
  native store increments, must also pass through `resolve/2` for int64 bounds.
  Compare a merged state with the prior state using `===` to skip unchanged writes;
  this module performs no storage operations. Min/max ties favor the right side,
  as in query aggregation, including numeric ties with different types.

  Numeric behavior follows query aggregates: integer sums wrap to int64, average
  sums retain exact integers, and float overflow is absorbing and resolves to
  null. Floating-point rounding/cancellation, overflow and mixed integer wrapping
  mean merge is not universally associative.
  """

  @operators [
    {"count", 0},
    {"count", 1},
    {"count_distinct", 1},
    {"sum", 1},
    {"min", 1},
    {"max", 1},
    {"avg", 1},
  ]
  @counts [{"count", 0}, {"count", 1}]
  @extremes [{"min", 1}, {"max", 1}]
  @numeric [{"sum", 1}, {"avg", 1}]

  @type operator ::
          {String.t(), non_neg_integer()}

  @doc "The supported operator names and exact arities."
  @spec operators() :: [operator()]
  def operators do
    @operators
  end

  @doc "An empty mergeable state, rather than an already resolved result."
  @spec default(operator()) :: term()
  def default(operator) when operator in @counts do
    0
  end

  # Hypex merges bitstrings bytewise; keep precision 8 (one register per byte).
  def default({"count_distinct", 1}) do
    Hypex.new(8, Hypex.Bitstring)
  end

  def default({"sum", 1}) do
    nil
  end

  def default(operator) when operator in @extremes do
    nil
  end

  def default({"avg", 1}) do
    {0, 0}
  end

  def default(_operator) do
    invalid!()
  end

  @doc "A state from one event's argument values; null inputs are skipped."
  @spec create(operator(), [term()]) :: term()
  def create({"count", 0}, []) do
    1
  end

  def create({"count", 1}, [nil]) do
    0
  end

  def create({"count", 1}, [_value]) do
    1
  end

  def create({"count_distinct", 1} = operator, [nil]) do
    default(operator)
  end

  def create({"count_distinct", 1} = operator, [value]) do
    Hypex.update(default(operator), value)
  end

  def create({"sum", 1}, [value]) when is_number(value) do
    value
  end

  def create({"sum", 1}, [_value]) do
    nil
  end

  def create(operator, [value]) when operator in @extremes do
    value
  end

  def create({"avg", 1}, [value]) when is_number(value) do
    {value, 1}
  end

  def create({"avg", 1}, [_value]) do
    {0, 0}
  end

  def create(_operator, _values) do
    invalid!()
  end

  @doc "Combines states for the same operator; the empty state is an identity."
  @spec merge(operator(), term(), term()) :: term()
  def merge(operator, left, right) when operator in @counts do
    left + right
  end

  def merge({"count_distinct", 1}, left, right) do
    Hypex.merge(left, right)
  end

  def merge(operator, :overflow, _right) when operator in @numeric do
    :overflow
  end

  def merge(operator, _left, :overflow) when operator in @numeric do
    :overflow
  end

  def merge({"sum", 1}, nil, right) do
    right
  end

  def merge({"sum", 1}, left, nil) do
    left
  end

  def merge({"sum", 1}, left, right) when is_integer(left) and is_integer(right) do
    Guardian.Query.Numeric.wrap(left + right)
  end

  def merge({"sum", 1}, left, right) do
    left + right
  catch
    :error, :badarith -> :overflow
  end

  def merge(operator, nil, right) when operator in @extremes do
    right
  end

  def merge(operator, left, nil) when operator in @extremes do
    left
  end

  def merge({"min", 1}, left, right) do
    if Guardian.Aggregation.Ordering.wins?(:min, left, right), do: left, else: right
  end

  def merge({"max", 1}, left, right) do
    if Guardian.Aggregation.Ordering.wins?(:max, left, right), do: left, else: right
  end

  def merge({"avg", 1}, {_sum, 0}, right) do
    right
  end

  def merge({"avg", 1}, left, {_sum, 0}) do
    left
  end

  def merge({"avg", 1}, {left_sum, left_count}, {right_sum, right_count}) do
    {left_sum + right_sum, left_count + right_count}
  catch
    :error, :badarith -> :overflow
  end

  def merge(_operator, _left, _right) do
    invalid!()
  end

  @doc "Resolves a merged window state to its storage-safe result."
  @spec resolve(operator(), term()) :: term()
  def resolve(operator, state) when operator in @counts do
    Guardian.Query.Numeric.int64_or_nil(state)
  end

  def resolve({"count_distinct", 1}, state) do
    state |> Hypex.cardinality() |> round()
  end

  def resolve(operator, :overflow) when operator in @numeric do
    nil
  end

  def resolve({"sum", 1}, state) do
    state
  end

  def resolve(operator, state) when operator in @extremes do
    state
  end

  def resolve({"avg", 1}, {_sum, 0}) do
    nil
  end

  def resolve({"avg", 1}, {sum, count}) do
    sum / count
  catch
    :error, :badarith -> nil
  end

  def resolve(_operator, _state) do
    invalid!()
  end

  defp invalid! do
    raise(ArgumentError, "unsupported counter aggregate or arity")
  end
end

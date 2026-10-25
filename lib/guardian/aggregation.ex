defmodule Guardian.Aggregation do
  @moduledoc """
  The aggregation registry, and the one way to run an aggregation.

  `fetch/1` turns a name into an aggregation: an implementation module, or
  `{module, option}` for a module shared by several aggregations (min and max, say).
  Callers treat the aggregation as opaque and run it through `empty/1`, `start/2`
  (or `start_row/3`), `merge/3` and `finish/2`, which call the module's callbacks,
  with the option as the first argument when there is one. Queries and counters use
  the same registry and the same configurations: every aggregate is available to
  TRACK. `empty/1` is the mergeable state of no rows; `default/1`, a query's result
  for no rows, is its finished value.
  """

  @names_and_mods [
    {"all", 1, Guardian.Aggregation.All},
    {"arbitrary", 1, Guardian.Aggregation.Arbitrary},
    {"avg", 1, Guardian.Aggregation.Avg},
    {"count", 0, Guardian.Aggregation.Count},
    {"count", 1, Guardian.Aggregation.Count},
    {"count_distinct", 1, Guardian.Aggregation.CountDistinct},
    {"count_if", 1, Guardian.Aggregation.CountIf},
    {"max", 1, {Guardian.Aggregation.MinMax, :max}},
    {"max_by", 2, {Guardian.Aggregation.MinMaxBy, :max}},
    {"max_n", 2, {Guardian.Aggregation.MinMaxN, :max}},
    {"max_n_by", 3, {Guardian.Aggregation.MinMaxNBy, :max}},
    {"min", 1, {Guardian.Aggregation.MinMax, :min}},
    {"min_by", 2, {Guardian.Aggregation.MinMaxBy, :min}},
    {"min_n", 2, {Guardian.Aggregation.MinMaxN, :min}},
    {"min_n_by", 3, {Guardian.Aggregation.MinMaxNBy, :min}},
    {"stddev", 1, {Guardian.Aggregation.Moments, :stddev_samp}},
    {"stddev_pop", 1, {Guardian.Aggregation.Moments, :stddev_pop}},
    {"stddev_samp", 1, {Guardian.Aggregation.Moments, :stddev_samp}},
    {"sum", 1, Guardian.Aggregation.Sum},
    {"var_pop", 1, {Guardian.Aggregation.Moments, :var_pop}},
    {"var_samp", 1, {Guardian.Aggregation.Moments, :var_samp}},
    {"variance", 1, {Guardian.Aggregation.Moments, :var_samp}},
  ]

  {names, arities, mods} = SuperList.unzip(@names_and_mods)
  @names names
  @names_and_arities SuperList.zip(names, arities)
  @name_to_aggregation SuperList.zip(names, mods) |> Map.new()

  @type t :: module | {module, term}

  def names do
    @names
  end

  def names_and_arities do
    @names_and_arities
  end

  @spec fetch(String.t()) :: {:ok, t} | {:error, :not_found}
  def fetch(name) do
    case Map.fetch(@name_to_aggregation, name) do
      {:ok, aggregation} ->
        {:ok, aggregation}

      :error ->
        {:error, :not_found}
    end
  end

  @spec fetch!(String.t()) :: t
  def fetch!(name) do
    {:ok, aggregation} = fetch(name)
    aggregation
  end

  @doc "The mergeable state of no rows: an identity of `merge/3`, distinct from any row's state."
  @spec empty(t) :: term
  def empty({mod, option}) do
    mod.empty(option)
  end

  def empty(mod) do
    mod.empty()
  end

  @doc "The result for a group with no rows: the finished empty state."
  @spec default(t) :: term
  def default(aggregation) do
    finish(aggregation, empty(aggregation))
  end

  @doc "An accumulator for one row, from the aggregation's argument values."
  @spec start(t, [term]) :: term
  def start({mod, option}, values) do
    apply(mod, :start, [option | values])
  end

  def start(mod, values) do
    apply(mod, :start, values)
  end

  @doc """
  Accumulators for one row, one per aggregation. `row` holds every aggregation's
  argument values in order, `arities` how many belong to each.
  """
  @spec start_row([t], [non_neg_integer], [term]) :: [term]
  def start_row([aggregation | aggregations], [arity | arities], row) do
    {values, row} = Enum.split(row, arity)
    [start(aggregation, values) | start_row(aggregations, arities, row)]
  end

  def start_row([], [], []) do
    []
  end

  @doc "Combines partial accumulators; floating-point rounding, overflow and wrapping mixed with floats can affect regrouping."
  @spec merge(t, term, term) :: term
  def merge({mod, option}, acc1, acc2) do
    mod.merge(option, acc1, acc2)
  end

  def merge(mod, acc1, acc2) do
    mod.merge(acc1, acc2)
  end

  @doc """
  The result from a group's accumulator. A list storage cannot hold becomes nil;
  scalars are returned as the callback produced them.
  """
  @spec finish(t, term) :: term
  def finish({mod, option}, acc) do
    mod.finish(option, acc)
    |> finish_result()
  end

  def finish(mod, acc) do
    mod.finish(acc)
    |> finish_result()
  end

  # Aggregates can add a list layer to valid input values. Check the completed
  # list once here, keeping the original term when valid. Scalars retain their
  # callback's policy, including raw counts outside int64.
  defp finish_result(value) when is_list(value) do
    if Guardian.Storage.Value.valid?(value), do: value, else: nil
  end

  defp finish_result(value) do
    value
  end
end

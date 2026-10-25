defmodule Guardian.Aggregation do
  @moduledoc """
  The aggregation registry, and the one way to run an aggregation.

  `fetch/1` turns a name into an aggregation: an implementation module, or
  `{module, option}` for a module shared by several aggregations (min and max, say).
  Callers treat the aggregation as opaque and run it through `default/1`, `start/2`
  (or `start_row/3`), `merge/3` and `finish/2`, which call the module's callbacks,
  with the option as the first argument when there is one.

  Counters opt in through `fetch_counter!/1`, using the same implementations with
  explicit policy options. `empty/1` returns a mergeable counter state, whereas
  `default/1` returns a query's final result for no rows.
  """

  @names_and_mods [
    {"all", 1, Guardian.Aggregation.All},
    {"arbitrary", 1, Guardian.Aggregation.Arbitrary},
    {"avg", 1, Guardian.Aggregation.Avg},
    {"count", 0, {Guardian.Aggregation.Count, :query}},
    {"count", 1, {Guardian.Aggregation.Count, :query}},
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

  # Explicit counter opt-in: only these configurations have suitable mergeable
  # states and the existing TRACK/LOOKUP semantics. Query registration alone does
  # not make an aggregate available to counters.
  @counter_aggregations [
    {{"count", 0}, {Guardian.Aggregation.Count, :counter}},
    {{"count", 1}, {Guardian.Aggregation.Count, :counter}},
    {{"count_distinct", 1}, {Guardian.Aggregation.CountDistinct, {8, Hypex.Bitstring}}},
    {{"sum", 1}, Guardian.Aggregation.Sum},
    {{"min", 1}, {Guardian.Aggregation.MinMax, :min}},
    {{"max", 1}, {Guardian.Aggregation.MinMax, :max}},
    {{"avg", 1}, {Guardian.Aggregation.Avg, :counter}},
  ]
  @counter_operators Enum.map(@counter_aggregations, &elem(&1, 0))
  @counter_by_operator Map.new(@counter_aggregations)

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

  @doc "The explicitly supported counter names and exact arities, in declaration order."
  def counter_operators do
    @counter_operators
  end

  @doc "The shared aggregate configured for a counter operator."
  @spec fetch_counter!({String.t(), non_neg_integer}) :: t
  def fetch_counter!(operator) do
    case Map.fetch(@counter_by_operator, operator) do
      {:ok, aggregation} -> aggregation
      :error -> raise ArgumentError, "unsupported counter aggregate or arity"
    end
  end

  @doc "An empty mergeable state for an opted-in aggregate, unlike default's final result."
  @spec empty(t) :: term
  def empty({mod, option}) do
    mod.empty(option)
  end

  def empty(mod) do
    mod.empty()
  end

  @doc "The result for a group with no rows."
  @spec default(t) :: term
  def default({mod, option}) do
    mod.default(option)
  end

  def default(mod) do
    mod.default()
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
  # callback's policy, including raw query counts outside int64.
  defp finish_result(value) when is_list(value) do
    if Guardian.Storage.Value.valid?(value), do: value, else: nil
  end

  defp finish_result(value) do
    value
  end
end

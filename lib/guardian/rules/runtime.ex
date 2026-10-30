defmodule Guardian.Rules.Runtime do
  @moduledoc """
  The dependency-level dispatcher called by compiled table modules, on one event's
  flattened row (dot-notation keys, as Storage stores it).

  - Reads: a field the row lacks is null. Names match exactly, and rules read the
    flattened row, so an object field has no value of its own.
  - SET, TRACK and LOOKUP write the one column they name, and UNSET removes the one
    column it names. Columns beneath it are other columns.
  - WHERE applies a statement only when it evaluates to `true`.

  Anything a statement raises crashes the rule worker (`Guardian.Rules.Runner`), which
  fails the request. An unreachable counter store is not a failure here: Execution
  answers its operator's missing result. Generated modules execute resolved counter
  plans through this same dispatcher.
  """

  alias Guardian.Counters.Definition
  alias Guardian.Counters.Execution
  alias Guardian.Counters.LookupOperation
  alias Guardian.Counters.TrackOperation
  alias Guardian.Lists

  @doc false
  def run(row, levels, %Guardian.Rules.Event{} = event) do
    Enum.reduce(levels, row, &run_level(&2, &1, event))
  end

  # Runs one dependency level: its SETs and UNSETs in order, then its counter statements
  # together, then their results into the row.
  defp run_level(row, steps, event) do
    # Complete scalar work and prepare counter ops before dispatching any counter.
    {row, counters} =
      Enum.reduce(steps, {row, []}, fn step, {row, counters} ->
        case step do
          %Guardian.Rules.Step.Set{} -> {set(row, step), counters}
          %Guardian.Rules.Step.Unset{} -> {unset(row, step), counters}
          _ -> {row, [{step, build_counter_operation(row, step)} | counters]}
        end
      end)

    {steps, prepared} = counters |> Enum.reverse() |> Enum.unzip()

    results =
      prepared
      |> Lists.filter(&prepared_to_run?/1)
      |> Enum.map(fn {:run, op} -> op end)
      |> Execution.run_counters(event.arrival, event.counters)
      |> Lists.unfilter(prepared, &prepared_to_run?/1)

    steps
    |> Enum.zip(results)
    |> Enum.reduce(row, fn {step, result}, row -> write_counter(row, step, result) end)
  end

  defp prepared_to_run?(prepared) do
    match?({:run, _op}, prepared)
  end

  # Writes one statement's outcome: :skip, whose WHERE was not true, leaves its field
  # alone.
  defp write_counter(row, _step, :skip) do
    row
  end

  defp write_counter(row, step, {:ok, value}) do
    Map.put(row, step.field, value)
  end

  # The statement's counter op, or :skip when its WHERE is not true.
  defp build_counter_operation(row, step) do
    # Step construction binds TRACK metadata; resolution binds LOOKUP targets.
    # Validation checks operators and windows before execution.
    definition = step_definition(step)

    if where_matches?(row, step.where_expr) do
      group =
        step.by_exprs
        |> Enum.map(&Guardian.Query.Evaluation.eval(row, &1))
        |> List.to_tuple()

      case step do
        %Guardian.Rules.Step.Track{} ->
          values = Enum.map(step.aggregate_expr.args, &Guardian.Query.Evaluation.eval(row, &1))
          {:run, %TrackOperation{definition: definition, group: group, values: values}}

        %Guardian.Rules.Step.Lookup{} ->
          {:run, %LookupOperation{definition: definition, group: group}}
      end
    else
      :skip
    end
  end

  # The counter a TRACK updates or a LOOKUP reads.
  defp step_definition(%Guardian.Rules.Step.Track{definition: %Definition{} = definition}) do
    definition
  end

  defp step_definition(%Guardian.Rules.Step.Lookup{target: target}) do
    target
  end

  def set(row, step) do
    if where_matches?(row, step.where_expr) do
      Map.put(row, step.field, Guardian.Query.Evaluation.eval(row, step.value_expr))
    else
      row
    end
  end

  def unset(row, step) do
    if where_matches?(row, step.where_expr) do
      Map.delete(row, step.field)
    else
      row
    end
  end

  defp where_matches?(_row, nil) do
    true
  end

  defp where_matches?(row, where_expr) do
    Guardian.Query.Evaluation.eval(row, where_expr) == true
  end
end

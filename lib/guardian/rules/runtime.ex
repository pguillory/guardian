defmodule Guardian.Rules.Runtime do
  @moduledoc """
  The dependency-level dispatcher called by compiled table modules, on one event's
  flattened row (dot-notation keys, as Storage stores it).

  - Reads: a field the row lacks is null. Names match exactly, and rules read the
    flattened row, so an object field has no value of its own.
  - SET, TRACK and LOOKUP write the one column they name, and UNSET removes the one
    column it names. Columns beneath it are other columns.
  - WHERE applies a statement only when it evaluates to `true`.

  SET/UNSET failures raise `Guardian.Rules.Runtime.Failure` naming the file and line, and
  the event is not stored. Counter failures supply their operator's missing result
  and continue. Exceptions are logged by kind only (`note_failure/3`), never a value.
  Generated modules execute resolved counter plans through this same dispatcher.
  """

  alias Guardian.Aggregation
  alias Guardian.Counters.Definition
  alias Guardian.Counters.Execution
  alias Guardian.Counters.LookupOperation
  alias Guardian.Counters.TrackOperation
  alias Guardian.Lists
  alias Guardian.Rules.Runtime.Failure
  require Logger

  @doc false
  def run(row, levels, %Guardian.Rules.Event{} = event) do
    Enum.reduce(levels, row, &level(&2, &1, event))
  end

  defp level(row, steps, event) do
    # Complete scalar work and prepare counter ops before dispatching any counter.
    {row, counters} =
      Enum.reduce(steps, {row, []}, fn step, {row, counters} ->
        case step do
          %Guardian.Rules.Step.Set{} -> {set(row, step), counters}
          %Guardian.Rules.Step.Unset{} -> {unset(row, step), counters}
          _ -> {row, [{step, prepare_counter(row, step)} | counters]}
        end
      end)

    {steps, prepared} = counters |> Enum.reverse() |> Enum.unzip()

    results =
      prepared
      |> Lists.filter(&runnable?/1)
      |> Enum.map(fn {:run, op} -> op end)
      |> Execution.run_counters(event.arrival, event.counters)
      |> Lists.unfilter(prepared, &runnable?/1)

    steps
    |> Enum.zip(results)
    |> Enum.reduce(row, fn {step, result}, row -> write_counter(row, step, result) end)
  end

  defp runnable?(prepared) do
    match?({:run, _op}, prepared)
  end

  # Writes one statement's outcome: a preparation outcome (:skip, :failed) or, for a
  # runnable statement, its run_counters result. A statement whose WHERE is not true
  # leaves its field alone. A failed one writes its operator's missing result;
  # preparation failures were logged when they happened, run failures here.
  defp write_counter(row, _step, :skip) do
    row
  end

  defp write_counter(row, step, :failed) do
    missing = Aggregation.default(Definition.aggregation(counter_definition(step)))
    Map.put(row, step.field, missing)
  end

  defp write_counter(row, step, {:ok, value}) do
    Map.put(row, step.field, value)
  end

  defp write_counter(row, step, {:error, kind}) do
    note_failure(step.file, step.line, kind)
    write_counter(row, step, :failed)
  end

  # The statement's counter op, :skip when its WHERE is not true, or :failed when
  # evaluating WHERE, BY or the TRACK arguments raised.
  defp prepare_counter(row, step) do
    # Step construction binds TRACK metadata; resolution binds LOOKUP targets.
    # Validation checks operators and windows before execution.
    definition = counter_definition(step)

    try do
      if applies?(row, step.where_expr) do
        group =
          step.by_exprs
          |> Enum.map(&Guardian.Query.Evaluation.eval(row, &1))
          |> List.to_tuple()

        case step do
          %Guardian.Rules.Step.Track{} ->
            values =
              Enum.map(step.aggregate_expr.args, &Guardian.Query.Evaluation.eval(row, &1))

            {:run, %TrackOperation{definition: definition, group: group, values: values}}

          %Guardian.Rules.Step.Lookup{} ->
            {:run, %LookupOperation{definition: definition, group: group}}
        end
      else
        :skip
      end
    catch
      kind, reason ->
        note_failure(
          step.file,
          step.line,
          Guardian.Failure.kind(kind, reason, __STACKTRACE__)
        )

        :failed
    end
  end

  defp counter_definition(%Guardian.Rules.Step.Track{definition: %Definition{} = definition}) do
    definition
  end

  defp counter_definition(%Guardian.Rules.Step.Lookup{target: target}) do
    target
  end

  def set(row, step) do
    guard(step, fn ->
      if applies?(row, step.where_expr) do
        Map.put(row, step.field, Guardian.Query.Evaluation.eval(row, step.value_expr))
      else
        row
      end
    end)
  end

  def unset(row, step) do
    guard(step, fn ->
      if applies?(row, step.where_expr) do
        Map.delete(row, step.field)
      else
        row
      end
    end)
  end

  @doc """
  Logs a rule failure by location and kind, at most once a minute per rule file on
  this node.
  """
  def note_failure(file, line, kind) do
    now = System.monotonic_time(:millisecond)
    table = Guardian.Rules.Server.failure_log_table()

    last =
      case :ets.whereis(table) do
        :undefined -> nil
        _ -> :ets.lookup(table, file)
      end

    case last do
      [{_file, at}] when now - at < 60_000 ->
        :ok

      nil ->
        Logger.warning("Rule #{file} line #{line} failed: #{kind}")

      _ ->
        :ets.insert(table, {file, now})
        Logger.warning("Rule #{file} line #{line} failed: #{kind}")
    end
  end

  defp guard(step, fun) do
    fun.()
  catch
    kind, reason ->
      failure_kind = Guardian.Failure.kind(kind, reason, __STACKTRACE__)
      note_failure(step.file, step.line, failure_kind)
      raise Failure, file: step.file, line: step.line, kind: failure_kind
  end

  defp applies?(_row, nil) do
    true
  end

  defp applies?(row, where_expr) do
    Guardian.Query.Evaluation.eval(row, where_expr) == true
  end
end

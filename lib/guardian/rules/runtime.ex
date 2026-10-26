defmodule Guardian.Rules.Runtime do
  @moduledoc """
  The dependency-level dispatcher called by compiled table modules, on one event's
  flattened row (dot-notation keys, as Storage stores it).

  - Reads: a field the row lacks is null. Names match ignoring case: an exact key wins,
    otherwise the first case-insensitive match in byte order (`Guardian.Rules.RowIndex`). Rules read
    the flattened row, so an object field has no value of its own.
  - `set/2` replaces the whole top-level field, removing every column under it in any
    case (`X`, `x.y`, `x..y`), then stores the value under the statement's spelling.
  - `unset/2` removes every column matching the path ignoring case, and every column
    beneath it.
  - WHERE applies a statement only when it evaluates to `true`.

  SET/UNSET failures raise `Guardian.Rules.Runtime.Failure` naming the file and line, and
  the event is not stored. Counter failures supply their operator's missing result
  and continue. Exceptions are logged by kind only (`note_failure/3`), never a value.
  Generated modules execute resolved counter plans through this same dispatcher.
  """

  alias Guardian.Lists
  alias Guardian.Rules.{CounterRuntime, RowIndex}
  alias Guardian.Rules.Runtime.Failure
  require Logger

  @doc "The row index the dispatcher threads through dependency levels."
  def start(row) do
    RowIndex.new(row)
  end

  @doc "The row once every statement has run."
  def finish(%RowIndex{row: row}) do
    row
  end

  @doc false
  def run(row, levels, %Guardian.Rules.Event{} = event) do
    levels
    |> Enum.reduce(start(row), &level(&2, &1, event))
    |> finish()
  end

  defp level(index, steps, event) do
    index = RowIndex.ensure(index)
    # Complete scalar work and prepare counter ops before dispatching any counter.
    {index, counters} =
      Enum.reduce(steps, {index, []}, fn step, {index, counters} ->
        case step do
          %Guardian.Rules.Step.Set{} -> {set(index, step), counters}
          %Guardian.Rules.Step.Unset{} -> {unset(index, step), counters}
          _ -> {index, [{step, prepare_counter(index, step)} | counters]}
        end
      end)

    {steps, prepared} = counters |> Enum.reverse() |> Enum.unzip()

    results =
      prepared
      |> Lists.filter(&runnable?/1)
      |> Enum.map(fn {:run, op} -> op end)
      |> CounterRuntime.run_counters(event)
      |> Lists.unfilter(prepared, &runnable?/1)

    steps
    |> Enum.zip(results)
    |> Enum.reduce(index, fn {step, result}, index -> write_counter(index, step, result) end)
  end

  defp runnable?(prepared) do
    match?({:run, _op}, prepared)
  end

  # Writes one statement's outcome: a preparation outcome (:skip, :failed) or, for a
  # runnable statement, its run_counters result. A statement whose WHERE is not true
  # leaves its field alone. A failed one writes its operator's missing result;
  # preparation failures were logged when they happened, run failures here.
  defp write_counter(index, _step, :skip) do
    index
  end

  defp write_counter(index, step, :failed) do
    RowIndex.put_field(index, step.field, CounterRuntime.missing(counter_definition(step)))
  end

  defp write_counter(index, step, {:ok, value}) do
    RowIndex.put_field(index, step.field, value)
  end

  defp write_counter(index, step, {:error, kind}) do
    note_failure(step.file, step.line, kind)
    write_counter(index, step, :failed)
  end

  # The statement's counter op, :skip when its WHERE is not true, or :failed when
  # evaluating WHERE, BY or the TRACK arguments raised.
  defp prepare_counter(index, step) do
    # Step construction binds TRACK metadata; resolution binds LOOKUP targets.
    # Validation checks operators and windows before execution.
    definition = counter_definition(step)

    try do
      context = context(index, step.reads)

      if applies?(context, step.where_expr) do
        group =
          step.by_exprs
          |> Enum.map(&Guardian.Query.Evaluation.eval(context, &1))
          |> List.to_tuple()

        case step do
          %Guardian.Rules.Step.Track{} ->
            values =
              Enum.map(step.aggregate_expr.args, &Guardian.Query.Evaluation.eval(context, &1))

            {:run, {:track, definition, group, values}}

          %Guardian.Rules.Step.Lookup{} ->
            {:run, {:lookup, definition, group}}
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

  defp counter_definition(%Guardian.Rules.Step.Track{
         definition: %Guardian.Rules.CounterDefinition{} = definition,
       }) do
    definition
  end

  defp counter_definition(%Guardian.Rules.Step.Lookup{target: target}) do
    target
  end

  def set(index, step) do
    guard(step, fn ->
      index = RowIndex.ensure(index)
      context = context(index, step.reads)

      if applies?(context, step.where_expr) do
        value = Guardian.Query.Evaluation.eval(context, step.value_expr)
        RowIndex.put_field(index, step.field, value)
      else
        index
      end
    end)
  end

  def unset(index, step) do
    guard(step, fn ->
      index = RowIndex.ensure(index)

      if applies?(context(index, step.reads), step.where_expr) do
        RowIndex.remove(index, String.split(step.field, "."))
      else
        index
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

  defp applies?(_context, nil) do
    true
  end

  defp applies?(context, where_expr) do
    Guardian.Query.Evaluation.eval(context, where_expr) == true
  end

  # The row, plus each name the statement reads that has no exact key, under that
  # name, from its case-insensitive match.
  defp context(%RowIndex{row: row} = index, reads) do
    Enum.reduce(reads, row, fn name, context ->
      case RowIndex.fetch(index, name) do
        {:ok, value} -> Map.put(context, name, value)
        :error -> context
      end
    end)
  end
end

defmodule Rules.Runtime do
  @moduledoc """
  The ordered-step dispatcher called by compiled table modules, on one event's
  flattened row (dot-notation keys, as Storage stores it).

  - Reads: a field the row lacks is null. Names match ignoring case: an exact key wins,
    otherwise the first case-insensitive match in byte order (`Rules.RowIndex`). Rules read
    the flattened row, so an object field has no value of its own.
  - `set/2` replaces the whole top-level field, removing every column under it in any
    case (`X`, `x.y`, `x..y`), then stores the value under the statement's spelling.
  - `unset/2` removes every column matching the path ignoring case, and every column
    beneath it.
  - WHERE applies a statement only when it evaluates to `true`.

  SET/UNSET failures raise `Rules.Runtime.Failure` naming the file and line, and
  the event is not stored. Counter failures supply their operator's missing result
  and continue. Exceptions are logged by kind only (`note_failure/3`), never a value.
  Generated modules execute resolved counter plans through this same dispatcher.
  """

  alias Rules.RowIndex
  require Logger

  defmodule Failure do
    @moduledoc "A rule statement raised. Carries only its location and the failure's kind."
    defexception [:file, :line, :kind]

    @impl true
    def message(%__MODULE__{} = e) do
      "rule #{e.file} line #{e.line} failed (#{e.kind}); the event was not stored"
    end
  end

  @doc "The row index the dispatcher threads through ordered statements."
  def start(row), do: RowIndex.new(row)

  @doc "The row once every statement has run."
  def finish(%RowIndex{row: row}), do: row

  @doc false
  def run(row, steps, %Rules.Event{} = event) do
    steps
    |> Enum.reduce(start(row), fn step, index ->
      case step do
        %Rules.Step.Set{} -> set(index, step)
        %Rules.Step.Unset{} -> unset(index, step)
        %Rules.Step.Track{} -> counter(index, step, event)
        %Rules.Step.Lookup{} -> counter(index, step, event)
      end
    end)
    |> finish()
  end

  defp counter(index, step, event) do
    index = RowIndex.ensure(index)
    definition = counter_definition(step)

    try do
      context = context(index, step.reads)

      if applies?(context, step.where_expr) do
        group = step.by_exprs |> Enum.map(&Query.Evaluation.eval(context, &1)) |> List.to_tuple()

        value =
          case step do
            %Rules.Step.Track{} ->
              values = Enum.map(step.aggregate_expr.args, &Query.Evaluation.eval(context, &1))
              Rules.CounterRuntime.track(definition, group, values, event)

            %Rules.Step.Lookup{} ->
              Rules.CounterRuntime.lookup(definition, group, event)
          end

        RowIndex.put_field(index, step.field, value)
      else
        index
      end
    catch
      kind, reason ->
        note_failure(step.file, step.line, Engine.failure_kind(kind, reason, __STACKTRACE__))
        RowIndex.put_field(index, step.field, Rules.CounterRuntime.missing(definition.operator))
    end
  end

  defp counter_definition(%Rules.Step.Track{} = step),
    do: Rules.CounterDefinition.from_track(step)

  defp counter_definition(%Rules.Step.Lookup{target: target}), do: target

  def set(index, step) do
    guard(step, fn ->
      index = RowIndex.ensure(index)
      context = context(index, step.reads)

      if applies?(context, step.where_expr) do
        value = Query.Evaluation.eval(context, step.value_expr)
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
    table = Rules.Server.failure_log_table()

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
      failure_kind = Engine.failure_kind(kind, reason, __STACKTRACE__)
      note_failure(step.file, step.line, failure_kind)
      raise Failure, file: step.file, line: step.line, kind: failure_kind
  end

  defp applies?(_context, nil), do: true
  defp applies?(context, where_expr), do: Query.Evaluation.eval(context, where_expr) == true

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

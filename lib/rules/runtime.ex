defmodule Rules.Runtime do
  @moduledoc """
  What a compiled table module calls for each statement, on one event's flattened row
  (dot-notation keys, as Storage stores it).

  - Reads: a field the row lacks is null. Names match ignoring case: an exact key wins,
    otherwise the first case-insensitive match in byte order (`Rules.RowIndex`). Rules read
    the flattened row, so an object field has no value of its own.
  - `set/2` replaces the whole top-level field, removing every column under it in any
    case (`X`, `x.y`, `x..y`), then stores the value under the statement's spelling.
  - `unset/2` removes every column matching the path ignoring case, and every column
    beneath it.
  - WHERE applies a statement only when it evaluates to `true`.

  A statement that raises raises `Rules.Runtime.Failure` naming the file and line, and
  the event is not stored. The failure is logged by kind only (`note_failure/3`),
  never a value.
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

  @doc "The state a compiled module threads through its statements, for `row`."
  def start(row), do: RowIndex.new(row)

  @doc "The row once every statement has run."
  def finish(%RowIndex{row: row}), do: row

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

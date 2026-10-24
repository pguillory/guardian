defmodule Rules.Runtime do
  @moduledoc """
  What a compiled table module calls for each statement, on one event's flattened row
  (dot-notation keys, as Storage stores it).

  - Reads: a field the row lacks is null. Names match ignoring case: an exact key wins,
    otherwise the first case-insensitive match in byte order (`index/1`). Rules read
    the flattened row, so an object field has no value of its own.
  - `set/3` replaces the whole top-level field, removing every column under it in any
    case (`X`, `x.y`, `x..y`), then stores the value under the statement's spelling.
  - `unset/3` removes every column matching the path ignoring case, and every column
    beneath it.
  - WHERE applies a statement only when it evaluates to `true`.

  A statement that raises raises `Rules.Runtime.Failure` naming the file and line, and
  the event is not stored. The failure is logged by kind only (`note_failure/3`),
  never a value.
  """

  alias Storage.Flattening
  require Logger

  defmodule Failure do
    @moduledoc "A rule statement raised. Carries only its location and the failure's kind."
    defexception [:file, :line, :kind]

    @impl true
    def message(%__MODULE__{} = e) do
      "rule #{e.file} line #{e.line} failed (#{e.kind}); the event was not stored"
    end
  end

  @doc "The row's keys grouped by their lowercase spelling, each group sorted."
  def index(row) do
    row
    |> Map.keys()
    |> Enum.group_by(&String.downcase/1)
    |> Map.new(fn {lower, keys} -> {lower, Enum.sort(keys)} end)
  end

  def set(row, index, step) do
    guard(step, fn ->
      context = context(row, index, step.reads)

      if applies?(context, step.where_expr) do
        value = Query.Evaluation.eval(context, step.value_expr)
        row |> remove_field(step.field) |> Map.put(step.field, value)
      else
        row
      end
    end)
  end

  def unset(row, index, step) do
    guard(step, fn ->
      if applies?(context(row, index, step.reads), step.where_expr) do
        remove_path(row, step.field)
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
  defp context(row, index, reads) do
    Enum.reduce(reads, row, fn name, context ->
      if Map.has_key?(row, name) do
        context
      else
        case Enum.find(Map.get(index, name, []), &Map.has_key?(row, &1)) do
          nil -> context
          key -> Map.put(context, name, Map.fetch!(row, key))
        end
      end
    end)
  end

  defp remove_field(row, field) do
    Map.reject(row, fn {key, _value} -> top_level_keys(key) |> hd() |> lower_eq(field) end)
  end

  defp remove_path(row, path) do
    segments = String.split(path, ".")

    Map.reject(row, fn {key, _value} ->
      keys = top_level_keys(key)

      length(keys) >= length(segments) and
        Enum.zip_with(segments, keys, &lower_eq(&2, &1)) |> Enum.all?()
    end)
  end

  # The object keys before the column's first list boundary: ["user", "name"] for
  # `user.name` and for `user.name..x`.
  defp top_level_keys(key) do
    if String.contains?(key, ["\"", "."]) do
      [keys | _] = Flattening.decode_path(key)
      keys
    else
      [key]
    end
  end

  defp lower_eq(key, lower), do: String.downcase(key) == lower
end

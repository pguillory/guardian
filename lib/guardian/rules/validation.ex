defmodule Guardian.Rules.Validation do
  @moduledoc "Pure per-step expression/counter checks and diagnostic construction."

  def errors(step) do
    Enum.map(scalar_errors(step), fn what ->
      error(step, :expression, "#{step.field}: #{what}", "rules cannot use #{what}")
    end) ++ counter_errors(step)
  end

  defp counter_errors(%Guardian.Rules.Step.Track{} = step) do
    operator_errors =
      if step.operator in Guardian.Counters.Aggregate.operators() do
        []
      else
        [
          error(
            step,
            :counter_aggregate,
            step.field,
            "TRACK requires count, count_distinct, sum, min, max or avg with a supported arity"
          ),
        ]
      end

    window_errors =
      if step.window_ms do
        []
      else
        [
          error(
            step,
            :counter_window,
            step.field,
            "LAST must have a positive integral total of at most 365 days (s, m, h, d, w)"
          ),
        ]
      end

    operator_errors ++ window_errors
  end

  defp counter_errors(%Guardian.Rules.Step.Lookup{} = step) do
    case Guardian.Rules.RuleSet.check_table(step.target_table) do
      :ok ->
        []

      {:error, _} ->
        [error(step, :counter_table, step.field, "FROM must use a valid ingested-table name")]
    end
  end

  defp counter_errors(_step) do
    []
  end

  def error(step, kind, detail, message) do
    error(step.file, step.line, kind, detail, message, step.table)
  end

  def error(file, line, kind, detail, message, table) do
    location = if line, do: "#{file} line #{line}", else: file

    %{
      table: table,
      file: file,
      line: line,
      kind: kind,
      detail: detail,
      message: "#{location}: #{message}",
    }
  end

  @not_scalar [
    {Guardian.AST.Node.AggregateFunctionCall, "aggregate functions"},
    {Guardian.AST.Node.Splat, "*"},
    {Guardian.AST.Node.As, "AS"},
    {Guardian.AST.Node.Ascending, "ASC"},
    {Guardian.AST.Node.Descending, "DESC"},
  ]

  def scalar_errors(step) do
    step
    |> Guardian.Rules.Step.inputs()
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn expr ->
      {_expr, found} =
        Guardian.AST.prewalk(expr, [], fn %mod{} = node, found ->
          case List.keyfind(@not_scalar, mod, 0) do
            {_mod, what} -> {node, [what | found]}
            nil -> {node, found}
          end
        end)

      found
    end)
    |> Enum.uniq()
  end
end

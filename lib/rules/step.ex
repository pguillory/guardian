defmodule Rules.Step.Set do
  @moduledoc "A parsed SET's inputs and diagnostic location."
  defstruct [
    :table,
    :file,
    :line,
    :index,
    :field,
    :source,
    :value_expr,
    :where_expr,
    kind: :set,
    reads: [],
  ]
end

defmodule Rules.Step.Unset do
  @moduledoc "A parsed UNSET's inputs and diagnostic location."
  defstruct [:table, :file, :line, :index, :field, :source, :where_expr, kind: :unset, reads: []]
end

defmodule Rules.Step.Track do
  @moduledoc "A parsed TRACK with definition identity and window coordinates."
  defstruct [
    :table,
    :file,
    :line,
    :index,
    :field,
    :source,
    :aggregate_expr,
    :where_expr,
    :operator,
    :window_ms,
    :bucket_ms,
    :identity,
    kind: :track,
    by_exprs: [],
    reads: [],
  ]
end

defmodule Rules.Step.Lookup do
  @moduledoc "A parsed LOOKUP; target is bound only after whole-set validation."
  defstruct [
    :table,
    :file,
    :line,
    :index,
    :field,
    :source,
    :counter,
    :target_table,
    :where_expr,
    :target,
    kind: :lookup,
    by_exprs: [],
    reads: [],
  ]
end

defmodule Rules.Step do
  @moduledoc "Builds typed rule steps and derives reads from their input expressions."

  def new(table, file, line, index, statement) do
    attrs = %{
      table: table,
      file: file,
      line: line,
      index: index,
      field: statement.field.name,
      source: AST.unparse(statement),
      where_expr: statement.where_expr,
    }

    step =
      case statement do
        %AST.Node.Statements.SetStatement{value_expr: expr} ->
          struct!(Rules.Step.Set, Map.put(attrs, :value_expr, expr))

        %AST.Node.Statements.UnsetStatement{} ->
          struct!(Rules.Step.Unset, attrs)

        %AST.Node.Statements.TrackStatement{} ->
          window_ms = Rules.CounterDefinition.window_ms(statement.last_expr.value)

          struct!(
            Rules.Step.Track,
            Map.merge(attrs, %{
              aggregate_expr: statement.aggregate_expr,
              by_exprs: statement.by_exprs,
              operator: {statement.aggregate_expr.name, length(statement.aggregate_expr.args)},
              window_ms: window_ms,
              bucket_ms: Rules.CounterDefinition.bucket_ms(window_ms),
              identity: {table, statement.field.name, digest(attrs.source)},
            })
          )

        %AST.Node.Statements.LookupStatement{} ->
          struct!(
            Rules.Step.Lookup,
            Map.merge(attrs, %{
              counter: statement.counter.name,
              target_table: if(statement.from_table, do: statement.from_table.name, else: table),
              by_exprs: statement.by_exprs,
            })
          )
      end

    %{step | reads: reads(inputs(step))}
  end

  def inputs(%Rules.Step.Set{} = step), do: [step.value_expr, step.where_expr]
  def inputs(%Rules.Step.Unset{} = step), do: [step.where_expr]

  def inputs(%Rules.Step.Track{} = step),
    do: step.aggregate_expr.args ++ step.by_exprs ++ [step.where_expr]

  def inputs(%Rules.Step.Lookup{} = step), do: step.by_exprs ++ [step.where_expr]

  defp digest(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  # Field names the inputs read, in first-read order.
  defp reads(exprs) do
    exprs
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn expr ->
      {_expr, names} =
        AST.prewalk(expr, [], fn
          %AST.Node.Identifier{name: name} = node, names -> {node, [name | names]}
          node, names -> {node, names}
        end)

      Enum.reverse(names)
    end)
    |> Enum.uniq()
  end
end

defmodule Guardian.Rules.Step.Set do
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

defmodule Guardian.Rules.Step.Unset do
  @moduledoc "A parsed UNSET's inputs and diagnostic location."
  defstruct [:table, :file, :line, :index, :field, :source, :where_expr, kind: :unset, reads: []]
end

defmodule Guardian.Rules.Step.Track do
  @moduledoc """
  A parsed TRACK with definition identity and window coordinates.
  Aggregation and definition are nil until validated plan construction resolves
  the configuration and prepares immutable counter metadata.
  """
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
    :aggregation,
    :window_ms,
    :bucket_ms,
    :identity,
    :definition,
    kind: :track,
    by_exprs: [],
    reads: [],
  ]
end

defmodule Guardian.Rules.Step.Lookup do
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

defmodule Guardian.Rules.Step do
  @moduledoc "Builds typed rule steps and derives reads from their input expressions."

  def new(table, file, line, index, statement) do
    attrs = %{
      table: table,
      file: file,
      line: line,
      index: index,
      field: statement.field.name,
      source: Guardian.AST.unparse(statement),
      where_expr: statement.where_expr,
    }

    step =
      case statement do
        %Guardian.AST.Node.Statements.SetStatement{value_expr: expr} ->
          struct!(Guardian.Rules.Step.Set, Map.put(attrs, :value_expr, expr))

        %Guardian.AST.Node.Statements.UnsetStatement{} ->
          struct!(Guardian.Rules.Step.Unset, attrs)

        %Guardian.AST.Node.Statements.TrackStatement{} ->
          window_ms = Guardian.Rules.CounterDefinition.window_ms(statement.last_expr.value)

          struct!(
            Guardian.Rules.Step.Track,
            Map.merge(attrs, %{
              aggregate_expr: statement.aggregate_expr,
              by_exprs: statement.by_exprs,
              operator: {statement.aggregate_expr.name, length(statement.aggregate_expr.args)},
              window_ms: window_ms,
              bucket_ms: Guardian.Rules.CounterDefinition.bucket_ms(window_ms),
              identity: {table, statement.field.name, digest(attrs.source)},
            })
          )

        %Guardian.AST.Node.Statements.LookupStatement{} ->
          struct!(
            Guardian.Rules.Step.Lookup,
            Map.merge(attrs, %{
              counter: statement.counter.name,
              target_table: if(statement.from_table, do: statement.from_table.name, else: table),
              by_exprs: statement.by_exprs,
            })
          )
      end

    %{step | reads: reads(inputs(step))}
  end

  def inputs(%Guardian.Rules.Step.Set{} = step) do
    [step.value_expr, step.where_expr]
  end

  def inputs(%Guardian.Rules.Step.Unset{} = step) do
    [step.where_expr]
  end

  def inputs(%Guardian.Rules.Step.Track{} = step) do
    step.aggregate_expr.args ++ step.by_exprs ++ [step.where_expr]
  end

  def inputs(%Guardian.Rules.Step.Lookup{} = step) do
    step.by_exprs ++ [step.where_expr]
  end

  defp digest(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end

  # Field names the inputs read, in first-read order.
  defp reads(exprs) do
    exprs
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn expr ->
      {_expr, names} =
        Guardian.AST.prewalk(expr, [], fn
          %Guardian.AST.Node.Identifier{name: name} = node, names -> {node, [name | names]}
          node, names -> {node, names}
        end)

      Enum.reverse(names)
    end)
    |> Enum.uniq()
  end
end

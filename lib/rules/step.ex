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
      end

    %{step | reads: reads(inputs(step))}
  end

  def inputs(%Rules.Step.Set{} = step), do: [step.value_expr, step.where_expr]
  def inputs(%Rules.Step.Unset{} = step), do: [step.where_expr]

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

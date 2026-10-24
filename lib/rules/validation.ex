defmodule Rules.Validation do
  @moduledoc "Pure expression checks, separate from rule-set error orchestration."

  @not_scalar [
    {AST.Node.AggregateFunctionCall, "aggregate functions"},
    {AST.Node.Splat, "*"},
    {AST.Node.As, "AS"},
    {AST.Node.Ascending, "ASC"},
    {AST.Node.Descending, "DESC"},
  ]

  def scalar_errors(step) do
    step
    |> Rules.Step.inputs()
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn expr ->
      {_expr, found} =
        AST.prewalk(expr, [], fn %mod{} = node, found ->
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

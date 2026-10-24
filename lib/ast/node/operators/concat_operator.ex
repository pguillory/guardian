defmodule AST.Node.Operators.ConcatOperator do
  use AST.Node.BinaryOperator, symbol: "||"

  defimpl Query.Eval do
    # `a || b || c` is one join of all its operands (Query.Function.Concat), so a cut
    # at the string cap ends it rather than leaving room for a later operand.
    def eval(%@for{} = expr, context) do
      expr
      |> @for.operands()
      |> Enum.map(&Query.Eval.eval(&1, context))
      |> Query.Function.Concat.eval_columns()
    end
  end

  @doc false
  def operands(expr), do: operands(expr, [])

  defp operands(%__MODULE__{left: left, right: right}, acc),
    do: operands(left, operands(right, acc))

  defp operands(expr, acc), do: [expr | acc]

  def eval(left, right) do
    Query.Function.Concat.eval(left, right)
  end
end

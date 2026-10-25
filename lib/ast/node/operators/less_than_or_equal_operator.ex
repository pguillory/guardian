defmodule Guardian.AST.Node.Operators.LessThanOrEqualOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "<="

  alias Guardian.AST.Node.Operators.Comparison

  defimpl Guardian.Query.Eval do
    def eval(%@for{} = expr, context) do
      Comparison.eval(expr, context, &@for.eval/2, &<=/2)
    end
  end

  def eval(left, right) when is_number(left) and is_number(right) do
    left <= right
  end

  def eval(left, right) when is_binary(left) and is_binary(right) do
    left <= right
  end

  def eval(_left, _right) do
    nil
  end
end

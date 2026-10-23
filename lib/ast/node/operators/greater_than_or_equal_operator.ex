defmodule AST.Node.Operators.GreaterThanOrEqualOperator do
  use AST.Node.BinaryOperator, symbol: ">="

  alias AST.Node.Operators.LessThanOrEqualOperator

  def eval(left, right) do
    LessThanOrEqualOperator.eval(right, left)
  end

  def rewrite(%__MODULE__{left: left, right: right}) do
    %LessThanOrEqualOperator{left: right, right: left}
  end
end

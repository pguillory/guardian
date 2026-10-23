defmodule AST.Node.Operators.GreaterThanOperator do
  use AST.Node.BinaryOperator, symbol: ">"

  alias AST.Node.Operators.LessThanOperator

  def eval(left, right) do
    LessThanOperator.eval(right, left)
  end

  def rewrite(%__MODULE__{left: left, right: right}) do
    %LessThanOperator{left: right, right: left}
  end
end

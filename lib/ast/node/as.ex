defmodule AST.Node.As do
  use AST.Node.BinaryOperator, symbol: "AS"

  def rewrite(%__MODULE__{left: expr}) do
    expr
  end
end

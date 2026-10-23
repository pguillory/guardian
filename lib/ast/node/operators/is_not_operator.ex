defmodule AST.Node.Operators.IsNotOperator do
  use AST.Node.BinaryOperator, symbol: "IS NOT"

  alias AST.Node.Operators.IsOperator
  alias AST.Node.Operators.NotOperator

  def rewrite(%__MODULE__{left: left, right: right}) do
    %NotOperator{right: %IsOperator{left: left, right: right}}
  end
end

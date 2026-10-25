defmodule Guardian.AST.Node.Operators.IsNotOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "IS NOT"

  alias Guardian.AST.Node.Operators.IsOperator
  alias Guardian.AST.Node.Operators.NotOperator

  def rewrite(%__MODULE__{left: left, right: right}) do
    %NotOperator{right: %IsOperator{left: left, right: right}}
  end
end

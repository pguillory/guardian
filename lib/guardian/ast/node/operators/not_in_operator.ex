defmodule Guardian.AST.Node.Operators.NotInOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "NOT IN"

  alias Guardian.AST.Node.Operators.InOperator
  alias Guardian.AST.Node.Operators.NotOperator

  def rewrite(%__MODULE__{left: left, right: right}) do
    %NotOperator{right: %InOperator{left: left, right: right}}
  end
end

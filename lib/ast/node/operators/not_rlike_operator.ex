defmodule Guardian.AST.Node.Operators.NotRlikeOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "NOT RLIKE"

  alias Guardian.AST.Node.Operators.NotOperator
  alias Guardian.AST.Node.Operators.RlikeOperator

  def rewrite(%__MODULE__{left: left, right: right}) do
    %NotOperator{right: %RlikeOperator{left: left, right: right}}
  end
end

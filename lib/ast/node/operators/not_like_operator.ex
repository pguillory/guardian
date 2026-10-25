defmodule Guardian.AST.Node.Operators.NotLikeOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "NOT LIKE"

  alias Guardian.AST.Node.Operators.LikeOperator
  alias Guardian.AST.Node.Operators.NotOperator

  def rewrite(%__MODULE__{left: left, right: right}) do
    %NotOperator{right: %LikeOperator{left: left, right: right}}
  end
end

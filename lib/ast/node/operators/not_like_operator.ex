defmodule AST.Node.Operators.NotLikeOperator do
  use AST.Node.BinaryOperator, symbol: "NOT LIKE"

  alias AST.Node.Operators.LikeOperator
  alias AST.Node.Operators.NotOperator

  def rewrite(%__MODULE__{left: left, right: right}) do
    %NotOperator{right: %LikeOperator{left: left, right: right}}
  end
end

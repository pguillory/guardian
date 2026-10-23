defmodule AST.Node.Operators.NotIlikeOperator do
  use AST.Node.BinaryOperator, symbol: "NOT ILIKE"

  alias AST.Node.Operators.IlikeOperator
  alias AST.Node.Operators.NotOperator

  def rewrite(%__MODULE__{left: left, right: right}) do
    %NotOperator{right: %IlikeOperator{left: left, right: right}}
  end
end

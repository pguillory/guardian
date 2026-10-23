defmodule AST.Node.Operators.NotRlikeOperator do
  use AST.Node.BinaryOperator, symbol: "NOT RLIKE"

  alias AST.Node.Operators.NotOperator
  alias AST.Node.Operators.RlikeOperator

  def rewrite(%__MODULE__{left: left, right: right}) do
    %NotOperator{right: %RlikeOperator{left: left, right: right}}
  end
end

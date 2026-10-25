defmodule Guardian.AST.Node.Operators.NotIlikeOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "NOT ILIKE"

  alias Guardian.AST.Node.Operators.IlikeOperator
  alias Guardian.AST.Node.Operators.NotOperator

  def rewrite(%__MODULE__{left: left, right: right}) do
    %NotOperator{right: %IlikeOperator{left: left, right: right}}
  end
end

defmodule AST.Node.Operators.IlikeOperator do
  use AST.Node.BinaryOperator, symbol: "ILIKE"

  alias AST.Node.Operators.LikeOperator

  def rewrite(%__MODULE__{left: left, right: right}) do
    left = %AST.Node.FunctionCall{name: "lower", args: [left]}
    right = %AST.Node.FunctionCall{name: "lower", args: [right]}
    %LikeOperator{left: left, right: right}
  end
end

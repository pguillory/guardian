defmodule AST.Node.Operators.IsOperator do
  use AST.Node.BinaryOperator, symbol: "IS"

  alias Query.ColumnOrConstant

  defimpl Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      column1 = Query.Eval.eval(left, context)
      column2 = Query.Eval.eval(right, context)
      ColumnOrConstant.map(column1, column2, &@for.eval/2)
    end
  end

  def eval(left, right) do
    left == right
  end
end

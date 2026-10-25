defmodule Guardian.AST.Node.Operators.NullSafeEqualOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "<=>"

  alias Guardian.Query.ColumnOrConstant

  defimpl Guardian.Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      column1 = Guardian.Query.Eval.eval(left, context)
      column2 = Guardian.Query.Eval.eval(right, context)
      ColumnOrConstant.map(column1, column2, &@for.eval/2)
    end
  end

  def eval(left, right) do
    left == right
  end
end

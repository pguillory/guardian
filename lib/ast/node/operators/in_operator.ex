defmodule AST.Node.Operators.InOperator do
  use AST.Node.BinaryOperator, symbol: "IN"

  alias Query.ColumnOrConstant

  defimpl Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      column1 = Query.Eval.eval(left, context)
      column2 = Query.Eval.eval(right, context)
      ColumnOrConstant.map(column1, column2, &@for.eval/2)
    end
  end

  def eval(nil, [_ | _]) do
    nil
  end

  def eval(left, [left | _right]) do
    true
  end

  def eval(left, [nil | right]) do
    case eval(left, right) do
      true -> true
      _ -> nil
    end
  end

  def eval(left, [_ | right]) do
    eval(left, right)
  end

  def eval(_, []) do
    false
  end

  def eval(_left, _right) do
    nil
  end
end

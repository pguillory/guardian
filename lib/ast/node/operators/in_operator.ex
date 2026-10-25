defmodule Guardian.AST.Node.Operators.InOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "IN"

  alias Guardian.Query.ColumnOrConstant

  defimpl Guardian.Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      column1 = Guardian.Query.Eval.eval(left, context)
      column2 = Guardian.Query.Eval.eval(right, context)
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

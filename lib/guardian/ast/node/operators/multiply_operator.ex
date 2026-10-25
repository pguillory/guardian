defmodule Guardian.AST.Node.Operators.MultiplyOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "*"

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Storage.Column

  defimpl Guardian.Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      column1 = Guardian.Query.Eval.eval(left, context)
      column2 = Guardian.Query.Eval.eval(right, context)
      ColumnOrConstant.map_or_nif(column1, column2, &@for.eval/2, &Column.multiply/2)
    end
  end

  # Integers wrap to int64, as the column NIF does; a float overflow is null
  # (Guardian.Query.Numeric).
  def eval(left, right) when is_integer(left) and is_integer(right) do
    Guardian.Query.Numeric.wrap(left * right)
  end

  def eval(left, right) when is_number(left) and is_number(right) do
    left * right
  catch
    :error, :badarith -> nil
  end

  def eval(_left, _right) do
    nil
  end
end

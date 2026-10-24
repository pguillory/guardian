defmodule AST.Node.Operators.SubtractOperator do
  use AST.Node.BinaryOperator, symbol: "-"

  alias Query.ColumnOrConstant
  alias Storage.Column

  defimpl Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      column1 = Query.Eval.eval(left, context)
      column2 = Query.Eval.eval(right, context)
      # A timestamp string minus seconds is evaluated per value: the NIF subtracts
      # only numbers, giving null for a string and an integer.
      if ColumnOrConstant.holds?(column1, :string) and ColumnOrConstant.holds?(column2, :integer) do
        ColumnOrConstant.map(column1, column2, &@for.eval/2)
      else
        ColumnOrConstant.map_or_nif(column1, column2, &@for.eval/2, &Column.subtract/2)
      end
    end
  end

  # Integers wrap to int64, as the column NIF does; a float overflow is null
  # (Query.Numeric).
  def eval(left, right) when is_integer(left) and is_integer(right) do
    Query.Numeric.wrap(left - right)
  end

  def eval(left, right) when is_number(left) and is_number(right) do
    left - right
  catch
    :error, :badarith -> nil
  end

  def eval(left, right) when is_binary(left) and is_integer(right) do
    Query.Function.DateSub.eval(left, right)
  end

  def eval(_left, _right) do
    nil
  end
end

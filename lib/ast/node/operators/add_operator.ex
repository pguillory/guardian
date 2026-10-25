defmodule Guardian.AST.Node.Operators.AddOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "+"

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Storage.Column

  defimpl Guardian.Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      column1 = Guardian.Query.Eval.eval(left, context)
      column2 = Guardian.Query.Eval.eval(right, context)
      # A timestamp string plus seconds is evaluated per value: the NIF adds only
      # numbers, giving null for a string and an integer.
      if timestamp_and_seconds?(column1, column2) or timestamp_and_seconds?(column2, column1) do
        ColumnOrConstant.map(column1, column2, &@for.eval/2)
      else
        ColumnOrConstant.map_or_nif(column1, column2, &@for.eval/2, &Column.add/2)
      end
    end

    defp timestamp_and_seconds?(strings, ints) do
      ColumnOrConstant.holds?(strings, :string) and ColumnOrConstant.holds?(ints, :integer)
    end
  end

  # Integers wrap to int64, as the column NIF does; a float overflow is null
  # (Guardian.Query.Numeric).
  def eval(left, right) when is_integer(left) and is_integer(right) do
    Guardian.Query.Numeric.wrap(left + right)
  end

  def eval(left, right) when is_number(left) and is_number(right) do
    left + right
  catch
    :error, :badarith -> nil
  end

  def eval(left, right) when is_binary(left) and is_integer(right) do
    Guardian.Query.Function.DateAdd.eval(left, right)
  end

  def eval(left, right) when is_integer(left) and is_binary(right) do
    Guardian.Query.Function.DateAdd.eval(right, left)
  end

  def eval(_left, _right) do
    nil
  end
end

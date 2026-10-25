defmodule Guardian.AST.Node.Operators.AndOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "AND"

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Storage.Column.Metadata
  require Metadata

  defimpl Guardian.Query.Eval do
    # col1   col2   result
    # -----  -----  ------
    # nil    nil    nil
    # nil    false  false
    # nil    true   nil
    # false  nil    false
    # false  false  false
    # false  true   false
    # true   nil    nil
    # true   false  false
    # true   true   true
    def eval(%@for{left: left, right: right}, context) do
      column1 = Guardian.Query.Eval.eval(left, context)

      case ColumnOrConstant.metadata(column1) do
        # Left side is always false.
        [Metadata.tuple(false_count: count, count: count) | _] ->
          column1

        [Metadata.tuple() | _] ->
          column2 = Guardian.Query.Eval.eval(right, context)
          ColumnOrConstant.evaluate(:and, column1, column2, &@for.eval/2)
      end
    end
  end

  def eval(true, true) do
    true
  end

  def eval(_, false) do
    false
  end

  def eval(false, _) do
    false
  end

  def eval(_left, _right) do
    nil
  end
end

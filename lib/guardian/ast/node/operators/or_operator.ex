defmodule Guardian.AST.Node.Operators.OrOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "OR"

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Query.NativeDispatch
  alias Guardian.Storage.Column.Metadata
  require Metadata

  defimpl Guardian.Query.Eval do
    # col1   col2   result
    # -----  -----  ------
    # nil    nil    nil
    # nil    false  nil
    # nil    true   true
    # false  nil    nil
    # false  false  false
    # false  true   true
    # true   nil    true
    # true   false  true
    # true   true   true
    def eval(%@for{left: left, right: right}, context) do
      column1 = Guardian.Query.Eval.eval(left, context)

      case ColumnOrConstant.metadata(column1) do
        # Left side is always true.
        [Metadata.tuple(true_count: count, count: count) | _] ->
          column1

        [Metadata.tuple() | _] ->
          column2 = Guardian.Query.Eval.eval(right, context)
          NativeDispatch.evaluate(:or, column1, column2, &@for.eval/2)
      end
    end
  end

  def eval(true, _) do
    true
  end

  def eval(_, true) do
    true
  end

  def eval(false, false) do
    false
  end

  def eval(_left, _right) do
    nil
  end
end

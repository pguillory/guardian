defmodule Guardian.Query.Function.If do
  alias Guardian.AST.Node.FunctionCall
  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Query.Constant
  alias Guardian.Query.Eval
  alias Guardian.Storage.Column.Metadata
  require Metadata

  # if/2
  def eval2(context, %FunctionCall{args: [expr1, expr2]}) do
    column1 = Eval.eval(expr1, context)

    case ColumnOrConstant.metadata(column1) do
      [Metadata.tuple(true_count: count, count: count) | _] ->
        Eval.eval(expr2, context)

      [Metadata.tuple(true_count: 0, count: count) | _] ->
        Constant.duplicate(nil, count)

      [Metadata.tuple() | _] ->
        column2 = Eval.eval(expr2, context)
        ColumnOrConstant.map(column1, column2, &__MODULE__.eval/2)
    end
  end

  # if/3
  def eval2(context, %FunctionCall{args: [expr1, expr2, expr3]}) do
    column1 = Eval.eval(expr1, context)

    case ColumnOrConstant.metadata(column1) do
      [Metadata.tuple(true_count: count, count: count) | _] ->
        Eval.eval(expr2, context)

      [Metadata.tuple(false_count: count, count: count) | _] ->
        Eval.eval(expr3, context)

      [Metadata.tuple(true_count: 0, false_count: 0, count: count) | _] ->
        Constant.duplicate(nil, count)

      [Metadata.tuple() | _] ->
        column2 = Eval.eval(expr2, context)
        column3 = Eval.eval(expr3, context)
        ColumnOrConstant.map(column1, column2, column3, &__MODULE__.eval/3)
    end
  end

  def eval(true, then_value) do
    then_value
  end

  def eval(_, _then_value) do
    nil
  end

  def eval(true, then_value, _else_value) do
    then_value
  end

  def eval(false, _then_value, else_value) do
    else_value
  end

  def eval(_, _then_value, _else_value) do
    nil
  end
end

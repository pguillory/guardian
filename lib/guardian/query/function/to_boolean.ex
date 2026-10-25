defmodule Guardian.Query.Function.ToBoolean do
  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Storage.Column

  # to_boolean/1
  def eval2(context, %Guardian.AST.Node.FunctionCall{args: [expr1]}) do
    column1 = Guardian.Query.Eval.eval(expr1, context)
    ColumnOrConstant.map_or_nif(column1, &__MODULE__.eval/1, &Column.to_boolean/1)
  end

  def eval(true) do
    true
  end

  def eval(false) do
    false
  end

  def eval(_) do
    nil
  end
end

defmodule Guardian.Query.Function.ToBoolean do
  alias Guardian.Query.ColumnOrConstant

  # to_boolean/1
  def eval2(context, %Guardian.AST.Node.FunctionCall{args: [expr1]}) do
    column1 = Guardian.Query.Eval.eval(expr1, context)
    ColumnOrConstant.evaluate(:to_boolean, column1, &__MODULE__.eval/1)
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

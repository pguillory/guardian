defmodule Query.Function.ToString do
  alias Query.ColumnOrConstant
  alias Storage.Column

  # to_string/1
  def eval2(context, %AST.Node.FunctionCall{args: [expr1]}) do
    column1 = Query.Eval.eval(expr1, context)
    ColumnOrConstant.map_or_nif(column1, &__MODULE__.eval/1, &Column.to_string/1)
  end

  def eval(string) when is_binary(string) do
    string
  end

  def eval(_) do
    nil
  end
end

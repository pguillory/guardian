defmodule Guardian.Query.Function.ToString do
  @moduledoc """
  `to_string(x)`: the string form of x (`Guardian.Query.Text.form/2`), cut to the string cap;
  a string as it is; null for null.
  """

  alias Guardian.Query.ColumnOrConstant

  # to_string/1
  def eval2(context, %Guardian.AST.Node.FunctionCall{args: [expr1]}) do
    column1 = Guardian.Query.Eval.eval(expr1, context)
    ColumnOrConstant.evaluate(:to_string, column1, &__MODULE__.eval/1)
  end

  def eval(string) when is_binary(string) do
    string
  end

  def eval(value) do
    Guardian.Query.Text.form(value, Guardian.Query.Text.max_bytes())
  end
end

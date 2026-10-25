defmodule Guardian.Query.Function.ToString do
  @moduledoc """
  `to_string(x)`: the string form of x (`Guardian.Query.Text.form/2`), cut to the string cap;
  a string as it is; null for null.
  """

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Storage.Column

  # to_string/1
  def eval2(context, %Guardian.AST.Node.FunctionCall{args: [expr1]}) do
    column1 = Guardian.Query.Eval.eval(expr1, context)

    if identity?(column1),
      do: ColumnOrConstant.map_or_nif(column1, &__MODULE__.eval/1, &Column.to_string/1),
      else: ColumnOrConstant.map(column1, &__MODULE__.eval/1)
  end

  # A column of only strings and nulls is its own result, which the NIF returns at
  # once; any other column is rendered value by value. A constant always goes to
  # map_or_nif, which evaluates it once with eval/1.
  defp identity?(%Guardian.Query.Constant{}) do
    true
  end

  defp identity?(column) do
    Column.null_count(column) + Column.string_count(column) == Column.count(column)
  end

  def eval(string) when is_binary(string) do
    string
  end

  def eval(value) do
    Guardian.Query.Text.form(value, Guardian.Query.Text.max_bytes())
  end
end

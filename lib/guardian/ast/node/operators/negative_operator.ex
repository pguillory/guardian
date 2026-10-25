defmodule Guardian.AST.Node.Operators.NegativeOperator do
  use Guardian.AST.Node

  alias Guardian.Query.ColumnOrConstant

  @enforce_keys [:right]
  defstruct [:right]

  defimpl Guardian.Query.Eval do
    def eval(%@for{right: right}, context) do
      column2 = Guardian.Query.Eval.eval(right, context)
      ColumnOrConstant.map(column2, &@for.eval/1)
    end
  end

  def to_source(%__MODULE__{right: right}) do
    "- " <> Guardian.AST.unparse(right)
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:right], acc, pre, post)
  end

  def eval(value) when is_integer(value), do: Guardian.Query.Numeric.wrap(-value)

  def eval(value) when is_float(value) do
    -value
  end

  def eval(_) do
    nil
  end
end

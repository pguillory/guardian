defmodule AST.Node.Operators.NotOperator do
  use AST.Node

  alias Query.ColumnOrConstant
  alias Storage.Column

  @enforce_keys [:right]
  defstruct [:right]

  defimpl Query.Eval do
    def eval(%@for{right: right}, context) do
      column1 = Query.Eval.eval(right, context)
      ColumnOrConstant.map_or_nif(column1, &@for.eval/1, &Column.not_oper/1)
    end
  end

  def to_source(%__MODULE__{right: right}) do
    "NOT " <> AST.unparse(right)
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:right], acc, pre, post)
  end

  def eval(true) do
    false
  end

  def eval(false) do
    true
  end

  def eval(_) do
    nil
  end
end

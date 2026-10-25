defmodule Guardian.AST.Node.Operators.NotOperator do
  use Guardian.AST.Node

  alias Guardian.Query.NativeDispatch

  @enforce_keys [:right]
  defstruct [:right]

  defimpl Guardian.Query.Eval do
    def eval(%@for{right: right}, context) do
      column1 = Guardian.Query.Eval.eval(right, context)
      NativeDispatch.evaluate(:not, column1, &@for.eval/1)
    end
  end

  def to_source(%__MODULE__{right: right}) do
    "NOT " <> Guardian.AST.unparse(right)
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

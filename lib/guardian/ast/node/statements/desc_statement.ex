defmodule Guardian.AST.Node.Statements.DescStatement do
  use Guardian.AST.Node

  @enforce_keys [:expr]
  defstruct [:expr]

  def to_source(%__MODULE__{} = expr) do
    "DESC " <> Guardian.AST.unparse(expr.expr)
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:expr], acc, pre, post)
  end
end

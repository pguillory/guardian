defmodule Guardian.AST.Node.Parentheses do
  use Guardian.AST.Node

  @enforce_keys [:expr]
  defstruct [:expr]

  def rewrite(%__MODULE__{expr: expr}) do
    expr
  end

  def to_source(%__MODULE__{expr: expr}) do
    "(" <> Guardian.AST.unparse(expr) <> ")"
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:expr], acc, pre, post)
  end
end

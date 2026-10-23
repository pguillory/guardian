defmodule AST.Node.Statements.LetStatement do
  use AST.Node

  @enforce_keys [:key_expr, :value_expr]
  defstruct [:key_expr, :value_expr]

  def to_source(%__MODULE__{} = expr) do
    [
      "LET " <> AST.unparse(expr.key_expr),
      " = " <> AST.unparse(expr.value_expr),
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:key_expr, :value_expr], acc, pre, post)
  end
end

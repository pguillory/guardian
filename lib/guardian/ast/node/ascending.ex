defmodule Guardian.AST.Node.Ascending do
  use Guardian.AST.Node

  @enforce_keys [:left]
  defstruct [:left]

  def symbol, do: "ASC"

  def to_source(%__MODULE__{left: left}) do
    Guardian.AST.unparse(left) <> " " <> symbol()
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:left], acc, pre, post)
  end
end

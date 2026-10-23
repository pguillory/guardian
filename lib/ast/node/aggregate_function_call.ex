defmodule AST.Node.AggregateFunctionCall do
  use AST.Node

  @enforce_keys [:name, :args]
  defstruct [:name, :args]

  def to_source(%__MODULE__{name: name, args: args}) do
    name <> "(" <> Enum.map_join(args, ", ", &AST.unparse/1) <> ")"
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:args], acc, pre, post)
  end
end

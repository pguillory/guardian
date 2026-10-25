defmodule Guardian.AST.Node.Statements.NullStatement do
  use Guardian.AST.Node

  defstruct []

  def to_source(%__MODULE__{}) do
    ""
  end

  def traverse(%__MODULE__{} = expr, acc, _pre, _post) do
    {expr, acc}
  end
end

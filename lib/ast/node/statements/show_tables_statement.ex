defmodule AST.Node.Statements.ShowTablesStatement do
  use AST.Node

  defstruct []

  def to_source(%__MODULE__{}) do
    "SHOW TABLES"
  end

  def traverse(%__MODULE__{} = expr, acc, _pre, _post) do
    {expr, acc}
  end
end

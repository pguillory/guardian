defmodule Guardian.AST.Node.Statements.RuleClauses do
  # Not a node: optional clause rendering shared by the four rule statements.
  @moduledoc false

  def where_source(nil) do
    ""
  end

  def where_source(where_expr) do
    " WHERE " <> Guardian.AST.unparse(where_expr)
  end

  def by_source([]) do
    ""
  end

  def by_source(exprs) do
    " BY " <> Enum.map_join(exprs, ", ", &Guardian.AST.unparse/1)
  end
end

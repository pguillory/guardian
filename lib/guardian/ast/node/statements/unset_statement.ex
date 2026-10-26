defmodule Guardian.AST.Node.Statements.UnsetStatement do
  @moduledoc """
  A rule statement, `UNSET path [WHERE cond]`: removes a field (and everything
  beneath it) from each incoming event of the rule file's table. Parsed only by
  `Guardian.AST.Parser.parse_rules/1`.
  """

  use Guardian.AST.Node

  alias Guardian.AST.Node.Statements.RuleClauses

  @enforce_keys [:field]
  defstruct [:field, where_expr: nil]

  def to_source(%__MODULE__{} = expr) do
    "UNSET " <> Guardian.AST.unparse(expr.field) <> RuleClauses.where_source(expr.where_expr)
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:field, :where_expr], acc, pre, post)
  end
end

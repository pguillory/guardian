defmodule Guardian.AST.Node.Statements.SetStatement do
  @moduledoc """
  A rule statement, `SET field = expr [WHERE cond]`: sets a top-level field on each
  incoming event of the rule file's table. Parsed only by `Guardian.AST.Parser.parse_rules/1`.
  """

  use Guardian.AST.Node

  alias Guardian.AST.Node.Statements.RuleClauses

  @enforce_keys [:field, :value_expr]
  defstruct [:field, :value_expr, where_expr: nil]

  def to_source(%__MODULE__{} = expr) do
    "SET " <>
      Guardian.AST.unparse(expr.field) <>
      " = " <> Guardian.AST.unparse(expr.value_expr) <> RuleClauses.where_source(expr.where_expr)
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:field, :value_expr, :where_expr], acc, pre, post)
  end
end

defmodule Guardian.AST.Node.Statements.LookupStatement do
  @moduledoc """
  Counter rule syntax, `LOOKUP field = counter [FROM table] [BY expr, ...] [WHERE cond]`.
  Parsed only by `Guardian.AST.Parser.parse_rules/1`; Rules binds its target before execution.
  """

  use Guardian.AST.Node

  alias Guardian.AST.Node.Statements.RuleClauses

  @enforce_keys [:field, :counter]
  defstruct [:field, :counter, :from_table, by_exprs: [], where_expr: nil]

  def to_source(%__MODULE__{} = expr) do
    "LOOKUP " <>
      Guardian.AST.unparse(expr.field) <>
      " = " <>
      Guardian.AST.unparse(expr.counter) <>
      from_source(expr.from_table) <>
      RuleClauses.by_source(expr.by_exprs) <> RuleClauses.where_source(expr.where_expr)
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:field, :counter, :from_table, :by_exprs, :where_expr], acc, pre, post)
  end

  defp from_source(nil) do
    ""
  end

  defp from_source(table) do
    " FROM " <> Guardian.AST.unparse(table)
  end
end

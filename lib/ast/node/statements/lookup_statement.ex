defmodule AST.Node.Statements.LookupStatement do
  @moduledoc """
  Counter rule syntax, `LOOKUP field = counter [FROM table] [BY expr, ...] [WHERE cond]`.
  Parsed only by `AST.Parser.parse_rules/1`; execution is not yet enabled.
  """

  use AST.Node

  alias AST.Node.Statements.SetStatement
  alias AST.Node.Statements.TrackStatement

  @enforce_keys [:field, :counter]
  defstruct [:field, :counter, :from_table, by_exprs: [], where_expr: nil]

  def to_source(%__MODULE__{} = expr) do
    "LOOKUP " <>
      AST.unparse(expr.field) <>
      " = " <>
      AST.unparse(expr.counter) <>
      from_source(expr.from_table) <>
      TrackStatement.by_source(expr.by_exprs) <> SetStatement.where_source(expr.where_expr)
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:field, :counter, :from_table, :by_exprs, :where_expr], acc, pre, post)
  end

  defp from_source(nil), do: ""
  defp from_source(table), do: " FROM " <> AST.unparse(table)
end

defmodule AST.Node.Statements.TrackStatement do
  @moduledoc """
  Counter rule syntax, `TRACK field = aggregate [BY expr, ...] [WHERE cond] LAST string`.
  Parsed only by `AST.Parser.parse_rules/1`; execution is not yet enabled.
  """

  use AST.Node

  alias AST.Node.Statements.SetStatement

  @enforce_keys [:field, :aggregate_expr, :last_expr]
  defstruct [:field, :aggregate_expr, :last_expr, by_exprs: [], where_expr: nil]

  def to_source(%__MODULE__{} = expr) do
    "TRACK " <>
      AST.unparse(expr.field) <>
      " = " <>
      AST.unparse(expr.aggregate_expr) <>
      by_source(expr.by_exprs) <>
      SetStatement.where_source(expr.where_expr) <> " LAST " <> AST.unparse(expr.last_expr)
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(
      expr,
      [:field, :aggregate_expr, :by_exprs, :where_expr, :last_expr],
      acc,
      pre,
      post
    )
  end

  @doc false
  def by_source([]), do: ""
  def by_source(exprs), do: " BY " <> Enum.map_join(exprs, ", ", &AST.unparse/1)
end

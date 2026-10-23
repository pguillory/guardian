defmodule AST.Node.Statements.SelectStatement do
  use AST.Node

  defstruct [
    :select_exprs,
    :from_expr,
    :where_expr,
    :group_by_exprs,
    :having_expr,
    :order_by_exprs,
    :limit_expr,
  ]

  def to_source(%__MODULE__{} = expr) do
    [
      "SELECT " <> Enum.map_join(expr.select_exprs, ", ", &AST.unparse/1),
      if expr.from_expr do
        " FROM " <> AST.unparse(expr.from_expr)
      end,
      if expr.where_expr do
        " WHERE " <> AST.unparse(expr.where_expr)
      end,
      if expr.group_by_exprs do
        " GROUP BY " <> Enum.map_join(expr.group_by_exprs, ", ", &AST.unparse/1)
      end,
      if expr.having_expr do
        " HAVING " <> AST.unparse(expr.having_expr)
      end,
      if expr.order_by_exprs do
        " ORDER BY " <> Enum.map_join(expr.order_by_exprs, ", ", &AST.unparse/1)
      end,
      if expr.limit_expr do
        " LIMIT " <> AST.unparse(expr.limit_expr)
      end,
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(
      expr,
      [
        :select_exprs,
        :from_expr,
        :where_expr,
        :group_by_exprs,
        :having_expr,
        :order_by_exprs,
        :limit_expr,
      ],
      acc,
      pre,
      post
    )
  end
end

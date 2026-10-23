defmodule AST.Node.Operators.BetweenOperator do
  use AST.Node

  alias AST.Node.Operators.AndOperator
  alias AST.Node.Operators.GreaterThanOrEqualOperator
  alias AST.Node.Operators.LessThanOrEqualOperator

  @enforce_keys [:left, :min_expr, :max_expr]
  defstruct [:left, :min_expr, :max_expr]

  def symbol, do: "BETWEEN"

  def to_source(%__MODULE__{left: left, min_expr: min_expr, max_expr: max_expr}) do
    "#{AST.unparse(left)} #{symbol()} #{AST.unparse(min_expr)} AND #{AST.unparse(max_expr)}"
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:left, :min_expr, :max_expr], acc, pre, post)
  end

  def rewrite(%__MODULE__{left: left, min_expr: min_expr, max_expr: max_expr}) do
    %AndOperator{
      left: %GreaterThanOrEqualOperator{left: left, right: min_expr},
      right: %LessThanOrEqualOperator{left: left, right: max_expr},
    }
  end
end

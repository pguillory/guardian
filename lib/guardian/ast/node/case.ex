defmodule Guardian.AST.Node.Case do
  use Guardian.AST.Node

  alias Guardian.AST.Node.Operators.EqualOperator

  @enforce_keys [:case_exprs, :when_exprs, :then_exprs]
  defstruct [:case_exprs, :when_exprs, :then_exprs, :else_expr]

  def to_source(%__MODULE__{} = expr) do
    "CASE " <>
      case expr.case_exprs do
        [case_expr] -> Guardian.AST.unparse(case_expr) <> " "
        [] -> ""
      end <>
      Enum.join(
        SuperList.map(expr.when_exprs, expr.then_exprs, fn when_expr, then_expr ->
          "WHEN " <>
            Guardian.AST.unparse(when_expr) <> " THEN " <> Guardian.AST.unparse(then_expr) <> " "
        end)
      ) <>
      if expr.else_expr do
        "ELSE " <> Guardian.AST.unparse(expr.else_expr) <> " "
      else
        ""
      end <>
      "END"
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:case_exprs, :when_exprs, :then_exprs, :else_expr], acc, pre, post)
  end

  def rewrite(%__MODULE__{
        case_exprs: case_exprs,
        when_exprs: when_exprs,
        then_exprs: then_exprs,
        else_expr: else_expr,
      }) do
    when_exprs = Enum.reverse(when_exprs)
    then_exprs = Enum.reverse(then_exprs)
    else_expr = else_expr || %Guardian.AST.Node.Literal{value: nil}

    case case_exprs do
      [case_expr] ->
        SuperList.reduce(when_exprs, then_exprs, else_expr, fn when_expr, then_expr, else_expr ->
          when_expr = %EqualOperator{left: case_expr, right: when_expr}
          %Guardian.AST.Node.FunctionCall{name: "if", args: [when_expr, then_expr, else_expr]}
        end)

      [] ->
        SuperList.reduce(when_exprs, then_exprs, else_expr, fn when_expr, then_expr, else_expr ->
          %Guardian.AST.Node.FunctionCall{name: "if", args: [when_expr, then_expr, else_expr]}
        end)
    end
  end
end

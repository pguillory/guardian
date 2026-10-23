defmodule Query.Function.Concat do
  alias Query.ColumnOrConstant

  # concat/2
  def eval2(context, %AST.Node.FunctionCall{args: [expr1, expr2]}) do
    column1 = Query.Eval.eval(expr1, context)
    column2 = Query.Eval.eval(expr2, context)
    ColumnOrConstant.map(column1, column2, &__MODULE__.eval/2)
  end

  # concat/3+
  def eval2(context, %AST.Node.FunctionCall{args: [expr1, expr2, expr3 | exprs]}) do
    expr_1_expr_2 = %AST.Node.FunctionCall{name: "concat", args: [expr1, expr2]}

    Query.Eval.eval(
      %AST.Node.FunctionCall{name: "concat", args: [expr_1_expr_2, expr3 | exprs]},
      context
    )
  end

  def eval(value1, value2) do
    string1 = to_string(value1)
    string2 = to_string(value2)
    Query.Limits.check_string_size!("concat", byte_size(string1) + byte_size(string2))
    string1 <> string2
  end

  def eval(value1, value2, value3) do
    value1 |> eval(value2) |> eval(value3)
  end

  def eval(value1, value2, value3, value4) do
    value1 |> eval(value2) |> eval(value3) |> eval(value4)
  end
end

defmodule Guardian.Query.Function.Coalesce do
  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Storage.Column.Metadata
  require Metadata

  # coalesce/1
  def eval2(context, %Guardian.AST.Node.FunctionCall{args: [expr1]}) do
    Guardian.Query.Eval.eval(expr1, context)
  end

  # coalesce/2
  def eval2(context, %Guardian.AST.Node.FunctionCall{args: [expr1, expr2]}) do
    column1 = Guardian.Query.Eval.eval(expr1, context)

    case ColumnOrConstant.metadata(column1) do
      [Metadata.tuple(null_count: 0) | _] ->
        column1

      [Metadata.tuple(null_count: count, count: count) | _] ->
        Guardian.Query.Eval.eval(expr2, context)

      [Metadata.tuple() | _] ->
        column2 = Guardian.Query.Eval.eval(expr2, context)
        ColumnOrConstant.map(column1, column2, &__MODULE__.eval/2)
    end
  end

  # Rewrite:
  #   coalesce(a, b, c, d)
  # To:
  #   coalesce(a, coalesce(b, coalesce(c, d)))
  def eval2(context, %Guardian.AST.Node.FunctionCall{args: [expr1 | exprs]}) do
    expr = %Guardian.AST.Node.FunctionCall{
      name: "coalesce",
      args: [
        expr1,
        %Guardian.AST.Node.FunctionCall{name: "coalesce", args: exprs},
      ],
    }

    Guardian.Query.Eval.eval(expr, context)
  end

  def eval(value) do
    value
  end

  def eval(nil, value) do
    value
  end

  def eval(value, _) do
    value
  end

  def eval(nil, nil, value) do
    value
  end

  def eval(nil, value, _) do
    value
  end

  def eval(value, _, _) do
    value
  end

  def eval(nil, nil, nil, value) do
    value
  end

  def eval(nil, nil, value, _) do
    value
  end

  def eval(nil, value, _, _) do
    value
  end

  def eval(value, _, _, _) do
    value
  end
end

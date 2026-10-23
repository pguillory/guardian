defmodule Query.Function.Jq do
  @moduledoc """
  `jq(program, json)`: runs a jq program over a JSON string in a sandboxed worker
  (`Query.Jq`). Returns the list of outputs, or nil when either argument is not a
  string or the input is not valid JSON. Compile errors and limits fail the query.
  """

  alias Query.ColumnOrConstant
  alias Query.Constant
  alias Storage.Column

  def eval2(context, %AST.Node.FunctionCall{args: [expr1, expr2]}) do
    column1 = Query.Eval.eval(expr1, context)
    column2 = Query.Eval.eval(expr2, context)

    case {column1, column2} do
      {%Constant{value: program, count: count}, %Constant{value: input}} ->
        Constant.duplicate(eval(program, input), count)

      _ ->
        count = ColumnOrConstant.count(column1)

        Enum.zip(values(column1, count), values(column2, count))
        |> Query.Jq.eval_rows()
        |> ColumnOrConstant.list_or_constant_to_column_or_constant()
    end
  end

  def eval(program, input) do
    [result] = Query.Jq.eval_rows([{program, input}])
    result
  end

  defp values(%Constant{value: value}, count), do: List.duplicate(value, count)
  defp values(column, _count), do: Column.to_list(column)
end

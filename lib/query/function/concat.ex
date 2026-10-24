defmodule Query.Function.Concat do
  alias Query.ColumnOrConstant

  def eval2(context, %AST.Node.FunctionCall{args: exprs}) do
    exprs |> Enum.map(&Query.Eval.eval(&1, context)) |> eval_columns()
  end

  @doc false
  # Shared with `||`, which joins a whole chain of operands in one call.
  def eval_columns([column1, column2]), do: ColumnOrConstant.map(column1, column2, &eval/2)
  def eval_columns(columns), do: ColumnOrConstant.map_n(columns, &join/1)

  def eval(value1, value2), do: join([value1, value2])

  @doc """
  The values joined: null is the empty string, any other value its string form
  (`Query.Text`). The result is cut to the string cap, and nothing past the cap is
  rendered. Joining stops at the first value cut, so the result is always a prefix of
  the whole join.
  """
  def join(values), do: join(values, Query.Text.max_bytes(), [])

  defp join([], _budget, acc), do: finish(acc)
  defp join([nil | values], budget, acc), do: join(values, budget, acc)

  defp join([value | values], budget, acc) do
    case Query.Text.form_cut(value, budget) do
      {string, false} -> join(values, budget - byte_size(string), [string | acc])
      {string, true} -> finish([string | acc])
    end
  end

  # One piece is returned as it is, without a copy.
  defp finish([]), do: ""
  defp finish([string]), do: string
  defp finish(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end

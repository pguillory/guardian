defmodule Query.Function.Replace do
  @moduledoc """
  `replace(s, 'pattern', replacement)`: replaces every non-overlapping match of a
  regular expression (`Query.Regex`, PCRE semantics) with the literal replacement.
  Null when `s` or the replacement is not a string, or `s` is not valid UTF-8.
  """

  alias Query.ColumnOrConstant
  alias Query.Constant
  alias Query.Evaluation

  # replace/3
  def eval2(context, %AST.Node.FunctionCall{args: [expr1, expr2, expr3]}) do
    with %AST.Node.Literal{value: pattern} when is_binary(pattern) <- expr2,
         {:ok, regex} <- Query.Regex.compile(pattern) do
      column1 = Query.Eval.eval(expr1, context)
      column3 = Query.Eval.eval(expr3, context)

      ColumnOrConstant.map(column1, column3, fn
        string, replacement when is_binary(string) and is_binary(replacement) ->
          Query.Regex.replace(regex, string, replacement)

        _, _ ->
          nil
      end)
    else
      _ ->
        Constant.duplicate(nil, Evaluation.context_count(context))
    end
  end
end

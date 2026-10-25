defmodule Guardian.Query.Function.Replace do
  @moduledoc """
  `replace(s, 'pattern', replacement)`: replaces every non-overlapping match of a
  regular expression (`Guardian.Query.Regex`, PCRE semantics) with the literal replacement.
  Null when `s` or the replacement is not a string, or `s` is not valid UTF-8, and in
  the other cases `Guardian.Query.Regex.replace/3` gives (the backtracking limit, `\\C`, too
  many matches). The result is cut to the string cap.
  """

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Query.Constant
  alias Guardian.Query.Evaluation

  # replace/3
  def eval2(context, %Guardian.AST.Node.FunctionCall{args: [expr1, expr2, expr3]}) do
    with %Guardian.AST.Node.Literal{value: pattern} when is_binary(pattern) <- expr2,
         {:ok, regex} <- Guardian.Query.Regex.compile(pattern) do
      column1 = Guardian.Query.Eval.eval(expr1, context)
      column3 = Guardian.Query.Eval.eval(expr3, context)

      ColumnOrConstant.map(column1, column3, fn
        string, replacement when is_binary(string) and is_binary(replacement) ->
          Guardian.Query.Regex.replace(regex, string, replacement)

        _, _ ->
          nil
      end)
    else
      _ ->
        Constant.duplicate(nil, Evaluation.context_count(context))
    end
  end
end

defmodule Query.Function.Replace do
  alias Query.ColumnOrConstant
  alias Query.Constant
  alias Query.Evaluation

  # replace/3
  def eval2(context, %AST.Node.FunctionCall{args: [expr1, expr2, expr3]}) do
    flags = Hyperscan.flag("HS_FLAG_SOM_LEFTMOST")
    mode = Hyperscan.mode("HS_MODE_BLOCK")

    with %AST.Node.Literal{value: pattern} when is_binary(pattern) <- expr2,
         {:ok, db} <- Hyperscan.compile(pattern, flags, mode),
         {:ok, scratch} <- Hyperscan.alloc_scratch(db) do
      column1 = Query.Eval.eval(expr1, context)
      column3 = Query.Eval.eval(expr3, context)

      ColumnOrConstant.map(column1, column3, fn
        string, replacement when is_binary(string) and is_binary(replacement) ->
          # Worst case: a match at every byte position, each replaced.
          worst = byte_size(string) + (byte_size(string) + 1) * byte_size(replacement)
          Query.Limits.check_string_size!("replace (worst case)", worst)
          {:ok, value} = Hyperscan.replace(db, string, replacement, scratch)
          value

        _, _ ->
          nil
      end)
    else
      _ ->
        Constant.duplicate(nil, Evaluation.context_count(context))
    end
  end
end

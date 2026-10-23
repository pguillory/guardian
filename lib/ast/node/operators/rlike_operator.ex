defmodule AST.Node.Operators.RlikeOperator do
  use AST.Node.BinaryOperator, symbol: "RLIKE"

  alias Query.ColumnOrConstant
  alias Query.Constant
  alias Query.Evaluation

  defimpl Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      with %AST.Node.Literal{value: value} when is_binary(value) <- right,
           {:ok, db} <- Hyperscan.compile(value, 0, Hyperscan.mode("HS_MODE_BLOCK")),
           {:ok, scratch} <- Hyperscan.alloc_scratch(db) do
        column1 = Query.Eval.eval(left, context)

        ColumnOrConstant.map(column1, fn
          string when is_binary(string) ->
            {:ok, value} = Hyperscan.match(db, string, scratch)
            value

          _ ->
            nil
        end)
      else
        _ ->
          Constant.duplicate(nil, Evaluation.context_count(context))
      end
    end
  end
end

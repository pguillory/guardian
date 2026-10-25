defmodule Guardian.AST.Node.Operators.RlikeOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "RLIKE"

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Query.Constant
  alias Guardian.Query.Evaluation

  defimpl Guardian.Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      with %Guardian.AST.Node.Literal{value: value} when is_binary(value) <- right,
           {:ok, regex} <- Guardian.Query.Regex.compile(value) do
        column1 = Guardian.Query.Eval.eval(left, context)

        ColumnOrConstant.map(column1, fn
          string when is_binary(string) ->
            Guardian.Query.Regex.matches(regex, string)

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

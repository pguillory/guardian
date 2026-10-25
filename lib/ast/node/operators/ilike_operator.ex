defmodule Guardian.AST.Node.Operators.IlikeOperator do
  use Guardian.AST.Node.BinaryOperator, symbol: "ILIKE"

  alias Guardian.AST.Node.Operators.LikeOperator
  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Query.Constant

  # LIKE on lowercased text. The lowercasing is internal and not cut to the string
  # cap (unlike lower()), so a long value matches ILIKE exactly as it matches LIKE.
  defimpl Guardian.Query.Eval do
    def eval(%@for{left: left, right: right}, context) do
      column1 = Guardian.Query.Eval.eval(left, context)

      case Guardian.Query.Eval.eval(right, context) do
        # A constant pattern, the usual case, is lowercased and compiled once.
        %Constant{value: pattern} ->
          compiled = LikeOperator.compile_constant(@for.downcase(pattern))
          ColumnOrConstant.map(column1, &LikeOperator.match(@for.downcase(&1), compiled))

        column2 ->
          ColumnOrConstant.map(column1, column2, &@for.eval/2)
      end
    end
  end

  def eval(value, pattern), do: LikeOperator.eval(downcase(value), downcase(pattern))

  @doc false
  def downcase(value) when is_binary(value), do: String.downcase(value)
  def downcase(value), do: value
end

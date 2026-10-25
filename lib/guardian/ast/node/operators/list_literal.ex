defmodule Guardian.AST.Node.Operators.ListLiteral do
  use Guardian.AST.Node

  alias Guardian.Query.ColumnOrConstant
  alias Guardian.Query.Constant
  alias Guardian.Query.Evaluation

  @enforce_keys [:exprs]
  defstruct [:exprs]

  defimpl Guardian.Query.Eval do
    def eval(%@for{exprs: []}, context) do
      %Constant{value: [], count: Evaluation.context_count(context)}
    end

    def eval(%@for{exprs: [_ | _] = exprs}, context) do
      columns = Enum.map(exprs, &Guardian.Query.Eval.eval(&1, context))
      ColumnOrConstant.map_n(columns)
    end
  end

  def to_source(%__MODULE__{exprs: exprs}) do
    "[" <> Enum.map_join(exprs, ", ", &Guardian.AST.unparse/1) <> "]"
  end

  def traverse(%__MODULE__{} = expr, acc, pre, post) do
    traverse_fields(expr, [:exprs], acc, pre, post)
  end
end

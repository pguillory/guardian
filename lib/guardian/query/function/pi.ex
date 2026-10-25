defmodule Guardian.Query.Function.Pi do
  alias Guardian.Query.Constant
  alias Guardian.Query.Evaluation

  def eval2(context, %Guardian.AST.Node.FunctionCall{args: []}) do
    Constant.duplicate(__MODULE__.eval(), Evaluation.context_count(context))
  end

  def eval do
    :math.pi()
  end
end

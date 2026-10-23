defmodule Query.Function.Pi do
  alias Query.Constant
  alias Query.Evaluation

  def eval2(context, %AST.Node.FunctionCall{args: []}) do
    Constant.duplicate(__MODULE__.eval(), Evaluation.context_count(context))
  end

  def eval do
    :math.pi()
  end
end

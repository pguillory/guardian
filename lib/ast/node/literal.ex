defmodule AST.Node.Literal do
  use AST.Node

  alias Query.Constant
  alias Query.Evaluation

  @enforce_keys [:value]
  defstruct [:value]

  defimpl Query.Eval do
    def eval(%@for{value: value}, context) do
      Constant.duplicate(value, Evaluation.context_count(context))
    end
  end

  def to_source(%__MODULE__{value: value}) do
    case value do
      nil ->
        "null"

      false ->
        "false"

      true ->
        "true"

      _ when is_number(value) ->
        to_string(value)

      _ when is_binary(value) ->
        AST.StringEncoding.encode_string(value)
    end
  end

  def traverse(%__MODULE__{} = expr, acc, _pre, _post) do
    {expr, acc}
  end
end

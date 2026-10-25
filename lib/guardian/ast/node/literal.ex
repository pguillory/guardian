defmodule Guardian.AST.Node.Literal do
  use Guardian.AST.Node

  alias Guardian.Query.Constant
  alias Guardian.Query.Evaluation

  @enforce_keys [:value]
  defstruct [:value]

  defimpl Guardian.Query.Eval do
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
        Guardian.AST.StringEncoding.encode_string(value)
    end
  end

  def traverse(%__MODULE__{} = expr, acc, _pre, _post) do
    {expr, acc}
  end
end

defmodule AST.Node.Identifier do
  use AST.Node

  alias Query.Constant
  alias Query.Evaluation
  alias Query.Evaluation.SegmentSnapshot

  @enforce_keys [:name]
  defstruct [:name]

  defimpl Query.Eval do
    def eval(%@for{name: name}, %SegmentSnapshot{} = snapshot) do
      Evaluation.read_column(snapshot, name)
    end

    def eval(%@for{name: name}, event) when is_map(event) do
      value = Map.get(event, name)
      %Constant{value: value, count: 1}
    end
  end

  def to_source(%__MODULE__{name: name}) do
    name
  end

  def traverse(%__MODULE__{} = expr, acc, _pre, _post) do
    {expr, acc}
  end
end

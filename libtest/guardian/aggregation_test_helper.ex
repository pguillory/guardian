defmodule Guardian.AggregationTestHelper do
  @moduledoc "Representative aggregate arguments for tests that cover every registered aggregate."

  @doc """
  Arguments for one row of `name/arity` built from `value`: the value itself, the
  value as its own ordering key for the `_by` forms, and n = 2 for the top-N forms.
  """
  def args(_name, 0, _value) do
    []
  end

  def args(_name, 1, value) do
    [value]
  end

  def args(name, 2, value) do
    if String.ends_with?(name, "_n"), do: [value, 2], else: [value, value]
  end

  def args(_name, 3, value) do
    [value, value, 2]
  end

  @doc "The same arguments as rule source text, using `field` as the value."
  def source_args(name, arity, field) do
    name |> args(arity, field) |> Enum.map_join(", ", &to_string/1)
  end
end

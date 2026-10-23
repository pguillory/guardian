defmodule Query.AmbiguousColumnError do
  @moduledoc """
  Raised when a column name in a query matches more than one stored column ignoring
  case.
  """

  defexception [:name, matches: []]

  @impl true
  def message(%__MODULE__{name: name, matches: matches}) do
    "ambiguous column #{name}: matches #{Enum.join(matches, ", ")}"
  end
end

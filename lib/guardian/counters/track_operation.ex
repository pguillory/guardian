defmodule Guardian.Counters.TrackOperation do
  @moduledoc """
  One TRACK statement ready to run for one event: add `values` to the counter that
  `definition` describes, in the `group` the statement's BY expressions evaluated to.
  It stays on this node: `Guardian.Counters.Execution` expands it into store operations.
  """
  alias Guardian.Counters.Definition

  @enforce_keys [:definition, :group, :values]
  defstruct [:definition, :group, :values]

  @type t :: %__MODULE__{definition: Definition.t(), group: tuple(), values: [term()]}
end

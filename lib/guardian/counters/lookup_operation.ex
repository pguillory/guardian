defmodule Guardian.Counters.LookupOperation do
  @moduledoc """
  One LOOKUP statement ready to run for one event: read the counter that `definition`
  describes, in the `group` the statement's BY expressions evaluated to. It stays on
  this node: `Guardian.Counters.Execution` expands it into store operations.
  """
  alias Guardian.Counters.Definition

  @enforce_keys [:definition, :group]
  defstruct [:definition, :group]

  @type t :: %__MODULE__{definition: Definition.t(), group: tuple()}
end

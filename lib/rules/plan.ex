defmodule Rules.Plan do
  @moduledoc """
  One table's validated rules in run order. Counter-aware preparation orders LOOKUPs
  and prerequisite SETs before the remaining SETs/TRACKs, with UNSETs last. Active
  rules still accept only SET/UNSET until C4c.

  `hash` includes diagnostic locations and resolved LOOKUP definitions, so future
  activation can recompile dependents when a target changes. Counter identities
  themselves ignore file/line. `Rules.RuleSet.prepare/1` also exposes unbound local
  candidates for activation selection; those candidates must not be compiled.
  """

  @enforce_keys [:table, :steps, :hash]
  defstruct [:table, :steps, :hash]
end

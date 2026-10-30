defmodule Guardian.Rules.Plan do
  @moduledoc """
  One table's validated rules in run order. Counter-aware preparation orders LOOKUPs
  and prerequisite SETs before the remaining SETs/TRACKs, with UNSETs last.
  `steps`, in deterministic flat metadata order, is the plan's only step
  representation. Execution levels are derived from it
  (`Guardian.Rules.DependencyGraph.levels/1`) once, when Compiler builds the module.

  `hash` includes diagnostic locations and resolved LOOKUP definitions, so
  activation can recompile dependents when a target changes. Counter identities
  themselves ignore file/line. `Guardian.Rules.RuleSet.prepare/1` also exposes unbound
  local candidates (locally valid, before LOOKUP resolution). Only successful
  whole-set resolution sets `resolved?`; Compiler refuses candidates, even for
  SET/UNSET-only tables.
  """

  @enforce_keys [:table, :steps, :hash]
  defstruct [:table, :steps, :hash, resolved?: false]
end

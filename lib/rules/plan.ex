defmodule Rules.Plan do
  @moduledoc """
  One table's validated rules, in run order: every SET (dependency order), then every
  UNSET. `hash` identifies the statements, so a reload recompiles only tables whose
  hash changed. Built by `Rules.RuleSet.validate/1`, compiled by `Rules.Compiler`.
  """

  @enforce_keys [:table, :steps, :hash]
  defstruct [:table, :steps, :hash]
end

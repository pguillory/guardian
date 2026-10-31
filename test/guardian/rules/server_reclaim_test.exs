defmodule Guardian.Rules.ServerReclaimTest do
  # Not async: shortens the node-wide wait before retired modules are reclaimed.
  use ExUnit.Case, async: false
  import Guardian.Test.Rules

  test "repeated edits reclaim retired modules" do
    Guardian.Test.Env.put(rules_reclaim_after_ms: 50)
    table = unique_table("rules_pool")
    remove_on_exit(table)
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 0")
    held = Guardian.Rules.lookup(table)

    for n <- 1..40, do: {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = #{n}")

    Guardian.Test.Polling.eventually(fn -> not Code.loaded?(held) end)
    refute function_exported?(held, :hash, 0)
    assert Guardian.Rules.lookup(table).table() == table
    assert Guardian.Rules.lookup(table).apply(%{}) == %{"x" => 40}
  end
end

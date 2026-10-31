defmodule Guardian.Web.MCP.RulesToolsBusyTest do
  # Not async: holds the one rule write lock, which would make other tests' writes busy.
  use ExUnit.Case, async: false
  import Guardian.Test.Rules

  alias Guardian.ObjectStore.Lock

  setup do
    {:ok, lock} = Lock.acquire(Guardian.Rules.store(), Guardian.Rules.Server.lock_key(), "x")
    on_exit(fn -> :ok = Lock.release(lock) end)
    :ok
  end

  test "a rule write finding the lock held fails as busy and saves nothing" do
    table = unique_table("rules_busy")
    assert Guardian.Rules.write_rule(table, "a", "SET x = 1") == {:error, :busy}
    assert Guardian.Rules.list_rules(table) == {:ok, []}
  end

  test "a busy MCP rule write is reported once its retries run out" do
    Guardian.Test.Env.put(mcp_rule_busy_retry_delays_ms: [0, 0])
    Guardian.Test.MCPClient.start()
    table = unique_table("mcp_rules_busy")

    {:ok, response} =
      Guardian.Test.MCPClient.call_tool("write_rule", %{
        "table" => table,
        "name" => "a",
        "source" => "SET x = 1",
      })

    assert response.result["isError"] == true
    assert [%{"type" => "text", "text" => message}] = response.result["content"]

    assert message ==
             "something else is editing the rules, so nothing was changed; try again in a few " <>
               "seconds (a lock left by an interrupted write expires within 2 minutes)"

    assert Guardian.Rules.list_rules(table) == {:ok, []}
  end
end

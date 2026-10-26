defmodule Guardian.Web.MCP.RulesToolsTest do
  use ExUnit.Case, async: false
  import Guardian.RulesTestHelper

  defp call(tool, arguments) do
    {:ok, response} = Guardian.MCPTestClient.call_tool(tool, arguments)
    [%{"type" => "text", "text" => text}] = response.result["content"]
    {response.result["isError"] == true, text}
  end

  defp ok(tool, arguments) do
    {false, text} = call(tool, arguments)
    Jason.decode!(text)
  end

  test "write, list, read and delete rules, and get computed fields back from send_events" do
    Guardian.MCPTestClient.start()
    table = unique_table("mcp_rules")

    assert ok("write_rule", %{
             "table" => table,
             "name" => "blocking",
             "source" => "SET is_blocked = true WHERE signal > 0.9",
           }) ==
             %{"saved" => true, "remaining_errors" => [], "nodes_not_yet_reloaded" => []}

    on_exit(fn -> Guardian.Rules.delete_rule(table, "blocking") end)

    assert ok("list_rules", %{"table" => table}) == [
             %{"table" => table, "name" => "blocking", "size" => 40},
           ]

    assert %{"source" => "SET is_blocked = true WHERE signal > 0.9"} =
             ok("read_rule", %{"table" => table, "name" => "blocking"})

    assert ok("send_events", %{
             "table" => table,
             "events" => [%{"signal" => 0.97}],
             "return_keys" => ["is_blocked"],
           }) ==
             %{
               "status" => 200,
               "results" => [%{"success" => true, "event" => %{"is_blocked" => true}}],
             }

    assert {true, text} =
             call("write_rule", %{
               "table" => table,
               "name" => "other",
               "source" => "SET is_blocked = false",
             })

    assert text =~
             "rejected; nothing was saved:\n#{table}/other.gsql line 1: is_blocked is defined differently"

    assert ok("delete_rule", %{"table" => table, "name" => "blocking"})["saved"] == true
    assert ok("list_rules", %{"table" => table}) == []

    assert {true, "no rule file " <> _} =
             call("read_rule", %{"table" => table, "name" => "blocking"})
  end

  test "counter writes reject invalid definitions and later rule failures preserve prior increments" do
    # Not about budgets: a larger one keeps healthy counter calls from timing out under load.
    Guardian.CounterBudgetHelper.relax()
    Guardian.MCPTestClient.start()
    table = unique_table("mcp_counter_validation")

    for source <- ["TRACK hits = count() LAST '0s'", "LOOKUP prior = absent"] do
      assert {true, message} =
               call("write_rule", %{"table" => table, "name" => "r", "source" => source})

      assert message =~ "rejected; nothing was saved"
      assert ok("list_rules", %{"table" => table}) == []
    end

    source = "TRACK hits = count() LAST '1h'; SET decision = test_raise(bad) + hits; UNSET secret"
    assert ok("write_rule", %{"table" => table, "name" => "r", "source" => source})["saved"]
    on_exit(fn -> Guardian.Rules.delete_rule(table, "r") end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert %{"results" => [failed, good]} =
               ok("send_events", %{
                 "table" => table,
                 "events" => [%{"bad" => 1, "secret" => "private"}, %{"secret" => "private"}],
                 "return_keys" => ["hits", "secret"],
               })

      assert failed["success"] == false
      assert failed["error"] =~ "the event was not stored"
      assert good == %{"success" => true, "event" => %{"hits" => 2, "secret" => nil}}
    end)

    assert Guardian.Storage.dump_table(table) == [%{"hits" => 2}]
  end
end

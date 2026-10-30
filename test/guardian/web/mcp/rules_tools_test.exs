defmodule Guardian.Web.MCP.RulesToolsTest do
  # Not async: relaxes the node-wide counter budgets and changes the shared rule store.
  use ExUnit.Case, async: false
  import Guardian.Test.Rules

  defp call(tool, arguments) do
    {:ok, response} = Guardian.Test.MCPClient.call_tool(tool, arguments)
    [%{"type" => "text", "text" => text}] = response.result["content"]
    {response.result["isError"] == true, text}
  end

  defp ok(tool, arguments) do
    {false, text} = call(tool, arguments)
    Jason.decode!(text)
  end

  test "write, list, read and delete rules, and get computed fields back from send_events" do
    Guardian.Test.MCPClient.start()
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
    Guardian.Test.Counters.Budget.relax()
    Guardian.Test.MCPClient.start()
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

  # The rule server on a fake S3 store, with the MCP busy retries waiting 0 ms.
  defp s3_rules(delays) do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    store = Guardian.Test.FakeS3.store(s3)
    {:ok, _pid} = restart_server(store, mcp_rule_busy_retry_delays_ms: delays)
    Guardian.Test.MCPClient.start()
    {s3, store}
  end

  defp lock_creates(s3) do
    lock_key = Guardian.Rules.Server.lock_key()

    s3
    |> Guardian.Test.FakeS3.requests()
    |> Enum.count(&(&1.method == "PUT" and String.ends_with?(&1.path, "/" <> lock_key)))
  end

  # Makes the next lock attempt busy: its create fails as if the lock were held, and
  # the read then finds it gone.
  defp busy_once(s3) do
    Guardian.Test.FakeS3.fault(s3, [{:status, 412}, {:status, 404}])
  end

  test "a busy rule write is tried again a few times, then reported" do
    {s3, store} = s3_rules([0, 0])
    {:ok, _lock} = Guardian.ObjectStore.Lock.acquire(store, Guardian.Rules.Server.lock_key(), "x")
    table = unique_table("mcp_rules_busy")

    assert {true, message} =
             call("write_rule", %{"table" => table, "name" => "a", "source" => "SET x = 1"})

    assert message ==
             "something else is editing the rules, so nothing was changed; try again in a few " <>
               "seconds (a lock left by an interrupted write expires within 2 minutes)"

    # The holder's create, then one per attempt: the first and two retries.
    assert lock_creates(s3) == 4
    assert Guardian.Test.FakeS3.objects(s3) |> Map.keys() == [Guardian.Rules.Server.lock_key()]
  end

  test "with no retry delays, a busy rule write is reported after one attempt" do
    {s3, store} = s3_rules([])
    {:ok, _lock} = Guardian.ObjectStore.Lock.acquire(store, Guardian.Rules.Server.lock_key(), "x")

    assert {true, message} =
             call("write_rule", %{
               "table" => unique_table("mcp_rules_busy_once"),
               "name" => "a",
               "source" => "SET x = 1",
             })

    assert message =~ "something else is editing the rules"
    assert lock_creates(s3) == 2
  end

  test "a busy rule write that frees up on a retry is saved, and retrying stops" do
    {s3, _store} = s3_rules([0, 0])
    table = unique_table("mcp_rules_busy_then_saved")
    busy_once(s3)
    on_exit(fn -> Guardian.Rules.delete_rule(table, "a") end)

    assert ok("write_rule", %{"table" => table, "name" => "a", "source" => "SET x = 1"})["saved"]
    # The busy attempt's create, the saving attempt's create and its release.
    assert lock_creates(s3) == 3
  end

  test "a busy rule delete stops retrying at its first other error" do
    {s3, _store} = s3_rules([0, 0])
    busy_once(s3)

    assert {true, message} =
             call("delete_rule", %{"table" => unique_table("mcp_rules_busy_gone"), "name" => "a"})

    assert message =~ "no rule file"
    # The busy attempt's create, the second attempt's create and its release.
    assert lock_creates(s3) == 3
  end
end

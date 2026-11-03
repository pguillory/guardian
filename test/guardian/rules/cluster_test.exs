defmodule Guardian.Rules.ClusterTest do
  # Starts peer nodes, so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false
  @moduletag :cluster
  import Guardian.Test.Rules

  setup do
    %{peer_node: peer_node} = context = Guardian.Test.Cluster.single_peer()
    # Peers are on this machine, so they share this node's rule folder.
    :ok = :erpc.call(peer_node, Guardian.Test.Cluster, :start_rules, [rule_path("")])
    context
  end

  defp peer_ingest(peer_node, table, events) do
    :erpc.call(peer_node, Guardian.Engine, :ingest_events, [table, events])
  end

  # The peer's rule server takes the write lock for a write on `table` and holds it:
  # before saving, it asks every other node to clear old code for the new rules, and a
  # second peer, whose rule server is suspended, does not answer for up to 10 s. Returns
  # a function that resumes the second peer and returns the held write's result.
  defp hold_write_lock(peer_node, table) do
    %{peer_node: slow_node} = Guardian.Test.Cluster.single_peer()
    :ok = :erpc.call(slow_node, Guardian.Test.Cluster, :start_rules, [rule_path("")])

    Guardian.Test.Polling.eventually(fn ->
      slow_node in :erpc.call(peer_node, Node, :list, [])
    end)

    slow_server = :erpc.call(slow_node, Process, :whereis, [Guardian.Rules.Server])
    :ok = :erpc.call(slow_node, :sys, :suspend, [slow_server])

    holder =
      Task.async(fn ->
        :erpc.call(peer_node, Guardian.Rules, :write_rule, [table, "a", "SET x = 1"])
      end)

    # The peer sends that request only while it holds the lock.
    Guardian.Test.Polling.eventually(fn ->
      {:messages, messages} = :erpc.call(slow_node, Process, :info, [slow_server, :messages])
      Enum.any?(messages, &match?({:"$gen_call", _from, {:purge_for, _hashes}}, &1))
    end)

    fn ->
      :ok = :erpc.call(slow_node, :sys, :resume, [slow_server])
      Task.await(holder, 30_000)
    end
  end

  test "a write reloads every node", %{peer_node: peer_node} do
    table = unique_table("rules_cluster")
    remove_on_exit(table)

    assert {:ok, %{unconfirmed: []}} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    assert [{:ok, %{"x" => 1}}] = peer_ingest(peer_node, table, [%{}])

    assert {:ok, %{unconfirmed: []}} =
             :erpc.call(peer_node, Guardian.Rules, :write_rule, [table, "a", "SET x = 2"])

    assert [{:ok, %{"x" => 2}}] = Guardian.Engine.ingest_events(table, [%{}])
  end

  test "a write conflicting with another node's saved write is rejected",
       %{peer_node: peer_node} do
    table = unique_table("rules_conflict")
    remove_on_exit(table)

    assert {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")

    assert {:error, {:rejected, _}} =
             :erpc.call(peer_node, Guardian.Rules, :write_rule, [table, "b", "SET x = 2"])
  end

  test "concurrent conflicting writes from two nodes: one wins, the other is busy or rejected",
       %{peer_node: peer_node} do
    table = unique_table("rules_race")
    remove_on_exit(table)

    here = Task.async(fn -> Guardian.Rules.write_rule(table, "a", "SET x = 1") end)

    there =
      Task.async(fn ->
        :erpc.call(peer_node, Guardian.Rules, :write_rule, [table, "b", "SET x = 2"])
      end)

    results = [Task.await(here, 30_000), Task.await(there, 30_000)]

    # The loser either overlapped the winner and found the lock held, or came after it
    # and found the conflicting rule.
    loser? = fn result ->
      result == {:error, :busy} or match?({:error, {:rejected, _}}, result)
    end

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, loser?) == 1
  end

  test "a write while another node holds the write lock fails as busy and saves nothing",
       %{peer_node: peer_node} do
    held = unique_table("rules_held")
    table = unique_table("rules_busy")
    remove_on_exit(held)
    remove_on_exit(table)
    release = hold_write_lock(peer_node, held)

    assert Guardian.Rules.write_rule(table, "a", "SET x = 1") == {:error, :busy}
    assert Guardian.Rules.list_rules(table) == {:ok, []}

    assert {:ok, _} = release.()
    assert Guardian.Rules.list_rules(table) == {:ok, []}
    assert {:ok, %{unconfirmed: []}} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
  end

  test "a busy MCP rule write is reported once its retries run out", %{peer_node: peer_node} do
    held = unique_table("mcp_rules_held")
    table = unique_table("mcp_rules_busy")
    remove_on_exit(held)
    remove_on_exit(table)
    Guardian.Test.Env.put(mcp_rule_busy_retry_delays_ms: [0, 0])
    Guardian.Test.MCPClient.start()
    release = hold_write_lock(peer_node, held)

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

    assert {:ok, _} = release.()
    assert Guardian.Rules.list_rules(table) == {:ok, []}
  end

  test "a node that missed a reload catches up at the next write", %{peer_node: peer_node} do
    table = unique_table("rules_missed")
    later = unique_table("rules_later")
    remove_on_exit(later)
    plant_file("#{table}/a.gsql", "SET x = 1")

    assert [{:ok, row}] = peer_ingest(peer_node, table, [%{}])
    refute Map.has_key?(row, "x")

    assert {:ok, %{unconfirmed: []}} =
             Guardian.Rules.write_rule(later, "a", "SET y = 1")

    assert [{:ok, %{"x" => 1}}] = peer_ingest(peer_node, table, [%{}])
  end

  # Parks a process in rule code on the peer (see the server test of the same
  # outcome for why).
  test "a write refused by a peer still running the replaced rules changes nothing",
       %{peer_node: peer_node} do
    table = unique_table("rules_cluster_recent")
    remove_on_exit(table)
    parked = :erpc.call(peer_node, Guardian.Test.Rules, :park_in_rules_module, [table])
    on_exit(fn -> send(parked, :release) end)
    # This write replaces the peer's parked module, leaving the process in old code.
    assert {:ok, %{unconfirmed: []}} = Guardian.Rules.write_rule(table, "a", "SET x = 1")

    assert Guardian.Rules.write_rule(table, "a", "SET x = 2") ==
             {:error, "rules changed too recently; try again"}

    assert Guardian.Rules.read_rule(table, "a") == {:ok, "SET x = 1"}
    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(table, [%{}])
    assert [{:ok, %{"x" => 1}}] = peer_ingest(peer_node, table, [%{}])

    ref = Process.monitor(parked)
    send(parked, :release)
    assert_receive {:DOWN, ^ref, :process, ^parked, :normal}
    assert {:ok, %{unconfirmed: []}} = Guardian.Rules.write_rule(table, "a", "SET x = 2")
    assert [{:ok, %{"x" => 2}}] = peer_ingest(peer_node, table, [%{}])
  end
end

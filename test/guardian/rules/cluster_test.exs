defmodule Guardian.Rules.ClusterTest do
  # Starts a peer node, so this module must not run concurrently with other tests.
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
end

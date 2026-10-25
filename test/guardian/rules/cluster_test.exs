defmodule Guardian.Rules.ClusterTest do
  # Starts a peer node, so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false
  import Guardian.RulesTestHelper

  setup do
    started_distribution = Guardian.TestCluster.ensure_distributed()
    data_root = Guardian.TestCluster.data_root()
    {peer, peer_node} = Guardian.TestCluster.start_peer(data_root)

    on_exit(fn ->
      :peer.stop(peer)
      File.rm_rf!(data_root)
      if started_distribution, do: Node.stop()
    end)

    %{peer_node: peer_node}
  end

  defp s3_cluster(peer_node, peer_env \\ []) do
    s3 = Guardian.FakeS3.start()
    on_exit(fn -> Guardian.FakeS3.stop(s3) end)
    store = Guardian.FakeS3.store(s3)
    {:ok, _} = restart_server(store)
    :ok = :erpc.call(peer_node, Guardian.TestCluster, :start_rules, [store, peer_env])
    s3
  end

  defp peer_ingest(peer_node, table, events),
    do: :erpc.call(peer_node, Guardian.Engine, :ingest_events, [table, events])

  test "a write reloads every node", %{peer_node: peer_node} do
    s3_cluster(peer_node)
    table = unique_table("rules_cluster")

    assert {:ok, %{unconfirmed: []}} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    assert [{:ok, %{"x" => 1}}] = peer_ingest(peer_node, table, [%{}])

    assert {:ok, %{unconfirmed: []}} =
             :erpc.call(peer_node, Guardian.Rules, :write_rule, [table, "a", "SET x = 2"])

    assert [{:ok, %{"x" => 2}}] = Guardian.Engine.ingest_events(table, [%{}])
  end

  test "concurrent conflicting writes from two nodes: one wins, the other is rejected",
       %{peer_node: peer_node} do
    s3_cluster(peer_node)
    table = unique_table("rules_race")

    here = Task.async(fn -> Guardian.Rules.write_rule(table, "a", "SET x = 1") end)

    there =
      Task.async(fn ->
        :erpc.call(peer_node, Guardian.Rules, :write_rule, [table, "b", "SET x = 2"])
      end)

    results = [Task.await(here, 30_000), Task.await(there, 30_000)]

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:rejected, _}}, &1)) == 1
  end

  test "a node that missed a reload catches up by polling", %{peer_node: peer_node} do
    s3 = s3_cluster(peer_node, rules_poll_ms: 100)
    table = unique_table("rules_missed")
    Guardian.FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = 1")

    Enum.reduce_while(1..100, nil, fn _, _ ->
      case peer_ingest(peer_node, table, [%{}]) do
        [{:ok, %{"x" => 1}}] -> {:halt, :ok}
        _ -> Process.sleep(50) && {:cont, nil}
      end
    end)
    |> then(&assert(&1 == :ok))
  end

  test "a local-folder store refuses writes while other nodes are connected", %{
    peer_node: _peer_node,
  } do
    dir = Path.join(System.tmp_dir!(), "rules_local_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store} = Guardian.Rules.Store.Local.new(dir)
    {:ok, _} = restart_server(store)

    assert {:error, message} =
             Guardian.Rules.write_rule(unique_table("rules_local"), "a", "SET x = 1")

    assert message =~ "a cluster needs an S3 rule store"
  end
end

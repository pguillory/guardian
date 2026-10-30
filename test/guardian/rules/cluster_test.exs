defmodule Guardian.Rules.ClusterTest do
  # Starts a peer node, so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false
  import Guardian.Test.Rules

  # Existing custom stores need not implement the optional shared?/1 callback.
  defmodule LegacyStore do
    @moduledoc false
    @behaviour Guardian.ObjectStore
    @impl true
    defdelegate list(config), to: Guardian.ObjectStore.S3
    @impl true
    defdelegate get(config, key, etag), to: Guardian.ObjectStore.S3
    @impl true
    defdelegate put(config, key, body, condition), to: Guardian.ObjectStore.S3
    @impl true
    defdelegate delete(config, key), to: Guardian.ObjectStore.S3
    @impl true
    defdelegate describe(config), to: Guardian.ObjectStore.S3
  end

  defmodule UnsharedStore do
    @moduledoc false
    @behaviour Guardian.ObjectStore
    @impl true
    defdelegate list(config), to: Guardian.ObjectStore.Local
    @impl true
    defdelegate get(config, key, etag), to: Guardian.ObjectStore.Local
    @impl true
    defdelegate put(config, key, body, condition), to: Guardian.ObjectStore.Local
    @impl true
    defdelegate delete(config, key), to: Guardian.ObjectStore.Local
    @impl true
    defdelegate describe(config), to: Guardian.ObjectStore.Local

    @impl true
    def shared?(_config) do
      false
    end
  end

  setup do
    Guardian.Test.Cluster.single_peer()
  end

  defp s3_cluster(peer_node, peer_env \\ []) do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    store = Guardian.Test.FakeS3.store(s3)
    {:ok, _} = restart_server(store)
    :ok = :erpc.call(peer_node, Guardian.Test.Cluster, :start_rules, [store, peer_env])
    s3
  end

  defp peer_ingest(peer_node, table, events) do
    :erpc.call(peer_node, Guardian.Engine, :ingest_events, [table, events])
  end

  test "capability dispatch loads a store before checking its callback", %{peer_node: peer_node} do
    assert :erpc.call(peer_node, :code, :is_loaded, [Guardian.ObjectStore.Local]) == false

    refute :erpc.call(peer_node, Guardian.ObjectStore, :shared?, [
             {Guardian.ObjectStore.Local, nil},
           ])
  end

  test "a write reloads every node", %{peer_node: peer_node} do
    s3_cluster(peer_node)
    table = unique_table("rules_cluster")

    assert {:ok, %{unconfirmed: []}} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    assert [{:ok, %{"x" => 1}}] = peer_ingest(peer_node, table, [%{}])

    assert {:ok, %{unconfirmed: []}} =
             :erpc.call(peer_node, Guardian.Rules, :write_rule, [table, "a", "SET x = 2"])

    assert [{:ok, %{"x" => 2}}] = Guardian.Engine.ingest_events(table, [%{}])
  end

  test "a write conflicting with another node's saved write is rejected",
       %{peer_node: peer_node} do
    s3_cluster(peer_node)
    table = unique_table("rules_conflict")

    assert {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")

    assert {:error, {:rejected, _}} =
             :erpc.call(peer_node, Guardian.Rules, :write_rule, [table, "b", "SET x = 2"])
  end

  test "concurrent conflicting writes from two nodes: one wins, the other is busy or rejected",
       %{peer_node: peer_node} do
    s3_cluster(peer_node)
    table = unique_table("rules_race")

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

  test "a node that missed a reload catches up by polling", %{peer_node: peer_node} do
    s3 = s3_cluster(peer_node, rules_poll_ms: 100)
    table = unique_table("rules_missed")
    Guardian.Test.FakeS3.put_object(s3, "#{table}/a.gsql", "SET x = 1")

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
    {:ok, store} = Guardian.ObjectStore.Local.new(dir)
    {:ok, _} = restart_server(store)

    assert {:error, message} =
             Guardian.Rules.write_rule(unique_table("rules_local"), "a", "SET x = 1")

    assert message ==
             "rules are in a local folder, which each node has its own copy of; " <>
               "a cluster needs an S3 rule store"
  end

  test "a custom unshared store refuses writes while other nodes are connected" do
    dir = Path.join(System.tmp_dir!(), "rules_custom_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, {_module, config}} = Guardian.ObjectStore.Local.new(dir)
    store = {UnsharedStore, config}
    {:ok, _} = restart_server(store)

    assert {:error, message} =
             Guardian.Rules.write_rule(unique_table("rules_custom"), "a", "SET x = 1")

    assert message ==
             "rules are in a local folder, which each node has its own copy of; " <>
               "a cluster needs an S3 rule store"

    assert Guardian.ObjectStore.list(store) == {:ok, []}
  end

  test "a custom store without the optional callback still accepts clustered writes" do
    s3 = Guardian.Test.FakeS3.start()
    on_exit(fn -> Guardian.Test.FakeS3.stop(s3) end)
    {_module, config} = Guardian.Test.FakeS3.store(s3)
    store = {LegacyStore, config}
    {:ok, _} = restart_server(store)
    table = unique_table("rules_legacy")

    assert {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    assert Guardian.Rules.read_rule(table, "a") == {:ok, "SET x = 1"}
  end
end

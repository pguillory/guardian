defmodule Guardian.Cluster.GroupByTest do
  # Starts a peer node. While a peer is connected every query in this VM fans out to
  # it, so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false
  import Guardian.TestHelpers, only: [eventually: 2, run_sql: 1]

  alias Guardian.Query.Executor
  alias Guardian.Storage.Column.Metadata
  require Metadata

  setup_all do
    %{peer_node: peer_node} = context = Guardian.TestCluster.single_peer()
    eventually(fn -> partition_nodes() == Enum.sort([node(), peer_node]) end, 10_000)
    context
  end

  setup do
    %{table: "cluster_group_by_#{System.unique_integer([:positive])}"}
  end

  defp partition_nodes do
    Executor.group_by_partitions()
    |> Enum.map(fn {node, _} -> node end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The first `n` candidate keys whose GROUP BY owner is on each node. Node names
  # change every run, so the keys are chosen at runtime: some groups merge on the test
  # node and some on the peer. `key_fun` turns a candidate into the routing key the
  # executor uses: the list of the row's group-by values.
  defp keys_owned_by_each_node(peer_node, n, key_fun) do
    partitions = Executor.group_by_partitions()
    candidates = Enum.map(0..199, key_fun)

    owned_by = fn owner ->
      candidates
      |> Enum.filter(fn key ->
        {node, _} = Guardian.Rendezvous.owner(key, partitions)
        node == owner
      end)
      |> Enum.take(n)
    end

    local_keys = owned_by.(node())
    peer_keys = owned_by.(peer_node)
    assert length(local_keys) == n, "too few candidate groups owned by the test node"
    assert length(peer_keys) == n, "too few candidate groups owned by the peer"
    local_keys ++ peer_keys
  end

  defp ingest_on(node, table, events) do
    outcomes = :erpc.call(node, Guardian.Engine, :ingest_events, [table, events])
    assert Enum.all?(outcomes, &match?({:ok, _}, &1)), inspect(outcomes)
  end

  # How many rows `node`'s own Storage holds for `table`, from its schema metadata.
  defp stored_count(node, table) do
    %{"k" => [Metadata.tuple(count: count) | _]} =
      :erpc.call(node, Guardian.Storage, :schema, [table])

    count
  end

  test "rows for the same groups on two nodes merge into one row per group",
       %{peer_node: peer_node, table: table} do
    keys = keys_owned_by_each_node(peer_node, 3, &["g#{&1}"])
    groups = Enum.map(keys, fn [k] -> k end)

    ingest_on(
      node(),
      table,
      Enum.flat_map(groups, &[%{"k" => &1, "n" => 1}, %{"k" => &1, "n" => 2}])
    )

    # n = 2 appears on both nodes, so count_distinct must count it once.
    # The minimum is on the test node and the maximum on the peer.
    ingest_on(
      peer_node,
      table,
      Enum.flat_map(groups, &[%{"k" => &1, "n" => 10}, %{"k" => &1, "n" => 2}])
    )

    # Each node holds only its own rows, so every merged count needs both nodes.
    assert stored_count(node(), table) == 2 * length(groups)
    assert stored_count(peer_node, table) == 2 * length(groups)

    rows =
      run_sql("""
      SELECT k, count(), sum(n), min(n), max(n), count_distinct(n)
      FROM #{table} GROUP BY k
      """)

    assert Enum.sort(rows) == Enum.sort(Enum.map(groups, &[&1, 4, 15, 1, 10, 3]))
  end

  test "rows for the same two-column groups on two nodes merge into one row per group",
       %{peer_node: peer_node, table: table} do
    owned_keys = keys_owned_by_each_node(peer_node, 2, &["k#{div(&1, 2)}", rem(&1, 2)])
    # Each key's sibling shares its k with the other j, so dropping j from the
    # grouping would merge pairs that must stay apart.
    keys = Enum.uniq(Enum.flat_map(owned_keys, fn [k, _j] -> [[k, 0], [k, 1]] end))

    events = fn n ->
      Enum.map(keys, fn [k, j] -> %{"k" => k, "j" => j, "n" => n} end)
    end

    ingest_on(node(), table, events.(1))
    ingest_on(peer_node, table, events.(5))

    rows = run_sql("SELECT k, j, count(), sum(n) FROM #{table} GROUP BY k, j")
    assert Enum.sort(rows) == Enum.sort(Enum.map(keys, fn [k, j] -> [k, j, 2, 6] end))
  end
end

defmodule Guardian.Cluster.MetadataTest do
  # Starts peer nodes. While a peer is connected every query in this VM fans out to
  # it, so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false
  @moduletag :cluster
  import Guardian.Test.Query, only: [run_sql: 1, with_time_limit: 2]

  alias Guardian.Storage.Column.Metadata
  require Metadata

  setup_all do
    Guardian.Test.Cluster.single_peer()
  end

  defp unique_table do
    "cluster_metadata_#{System.unique_integer([:positive])}"
  end

  defp ingest_on(node, table, events) do
    :erpc.call(node, Guardian.Engine, :ingest_events, [table, events])
  end

  test "the peer is part of the cluster", %{peer_node: peer_node} do
    assert peer_node in Guardian.Cluster.connected_nodes()
  end

  test "schema metadata merges every node's per-type counts", %{peer_node: peer_node} do
    table = unique_table()
    Guardian.Engine.ingest_events(table, [%{"a" => 1, "b" => "x"}])
    ingest_on(peer_node, table, [%{"a" => "one", "c" => true}, %{"a" => 2}])

    # Neither node has every column on its own.
    assert Map.keys(:erpc.call(peer_node, Guardian.Storage, :schema, [table])) == ["a", "c"]
    assert Map.keys(Guardian.Storage.schema(table)) == ["a", "b"]

    schema = Guardian.Cluster.Metadata.schema(table)
    assert Map.keys(schema) == ["a", "b", "c"]

    # Column "a" is an int on one node and mixed on the other; counts add up.
    assert [Metadata.tuple(count: 3, int_count: 2, string_count: 1) | _] = schema["a"]
    assert [Metadata.tuple(count: 1, string_count: 1) | _] = schema["b"]
    assert [Metadata.tuple(count: 1, true_count: 1) | _] = schema["c"]

    assert [table] in run_sql("SHOW TABLES")
    assert run_sql("DESC #{table}") == [["a"], ["b"], ["c"]]

    assert run_sql(
             "SELECT key, count, int_count, string_count FROM schema WHERE table = '#{table}' ORDER BY key"
           ) ==
             [["a", 3, 2, 1], ["b", 1, 0, 1], ["c", 1, 0, 0]]

    assert Enum.sort(run_sql("SELECT * FROM #{table}")) ==
             Enum.sort([[1, "x", nil], ["one", nil, true], [2, nil, nil]])
  end

  test "a table that exists only on the peer is visible", %{peer_node: peer_node} do
    table = unique_table()
    ingest_on(peer_node, table, [%{"only_remote" => 1}])

    assert Guardian.Storage.table_names() |> Enum.member?(table) == false
    assert [table] in run_sql("SHOW TABLES")
    assert run_sql("DESC #{table}") == [["only_remote"]]
    assert run_sql("SELECT * FROM #{table}") == [[1]]
  end

  test "an evaluation error on the peer fails the query", %{peer_node: peer_node} do
    table = unique_table()
    ingest_on(peer_node, table, [%{"v" => 1}, %{"v" => 2}])
    Guardian.Engine.ingest_events(table, [%{"v" => 3}])

    error =
      assert_raise Guardian.Query.Error, fn -> run_sql("SELECT test_raise(v) FROM #{table}") end

    assert error.message =~ "query evaluation failed"
    assert Enum.sort(run_sql("SELECT v FROM #{table}")) == [[1], [2], [3]]
  end

  test "a hung in-memory segment fails SELECT * at its lookup, other SELECTs at the time limit",
       %{peer_node: peer_node} do
    table = unique_table()
    ingest_on(peer_node, table, [%{"v" => 1}])

    [segment] =
      :erpc.call(peer_node, Guardian.Storage.MutableSegments, :get_mutable_segments, [table])

    :ok = :erpc.call(peer_node, :sys, :suspend, [segment])
    on_exit(fn -> :erpc.call(peer_node, :sys, :resume, [segment]) end)

    # The peer's schema read gives up on the segment after 5 s.
    error = assert_raise Guardian.Cluster.NodeError, fn -> run_sql("SELECT * FROM #{table}") end
    assert [{^peer_node, _reason}] = error.failures

    # A SELECT that names its columns makes no lookup; its scan waits on the segment
    # until the query's time limit.
    with_time_limit(500, fn ->
      error = assert_raise Guardian.Query.Error, fn -> run_sql("SELECT v FROM #{table}") end
      assert error.message =~ "time limit"
    end)
  end

  describe "with a node that has not started Storage" do
    setup do
      {peer, starting_node} = Guardian.Test.Cluster.start_peer(nil)

      data_root = Guardian.Test.Cluster.data_root()

      on_exit(fn ->
        :peer.stop(peer)
        File.rm_rf!(data_root)
      end)

      %{starting_node: starting_node, data_root: data_root}
    end

    test "it is left out until its Storage is ready", context do
      %{starting_node: starting_node, data_root: data_root, peer_node: peer_node} = context
      assert starting_node in Node.list()
      refute starting_node in Guardian.Cluster.connected_nodes()
      assert peer_node in Guardian.Cluster.connected_nodes()

      table = unique_table()
      Guardian.Engine.ingest_events(table, [%{"v" => 1}])
      assert [table] in run_sql("SHOW TABLES")
      assert run_sql("DESC #{table}") == [["v"]]
      assert run_sql("SELECT * FROM #{table}") == [[1]]
      # GROUP BY partitions still include it; their workers never read Guardian.Storage.
      assert run_sql("SELECT v, count() FROM #{table} GROUP BY v") == [[1, 1]]

      # Its Storage finishes starting, as at the end of a boot.
      :ok = :erpc.call(starting_node, Guardian.Test.Cluster, :start_storage, [data_root])
      ingest_on(starting_node, table, [%{"v" => 2, "w" => true}])

      assert starting_node in Guardian.Cluster.connected_nodes()
      assert run_sql("DESC #{table}") == [["v"], ["w"]]
      assert Enum.sort(run_sql("SELECT v FROM #{table}")) == [[1], [2]]
    end
  end
end

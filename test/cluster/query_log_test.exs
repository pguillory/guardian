defmodule Cluster.QueryLogTest do
  # Starts and stops a peer node. While a peer is connected every query in this VM fans
  # out to it, so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false

  setup do
    started_distribution = TestCluster.ensure_distributed()
    data_root = TestCluster.data_root()
    {peer, peer_node} = TestCluster.start_peer(data_root)
    # Peers run only Storage; give this one a recorder, so a row it recorded would show.
    {:ok, _} =
      :erpc.call(peer_node, GenServer, :start, [
        Web.QueryLog,
        [name: Web.QueryLog],
        [name: Web.QueryLog],
      ])

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(data_root)
      if started_distribution, do: Node.stop()
    end)

    %{peer_node: peer_node}
  end

  test "a query that fans out is recorded once, on the coordinating machine",
       %{peer_node: peer_node} do
    table = "query_log_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    Engine.ingest_events(table, [%{"v" => 1}])
    :erpc.call(peer_node, Engine, :ingest_events, [table, [%{"v" => 2}]])
    sql = "SELECT count() FROM #{table}"

    assert {:ok, _labels, [[2]]} = Web.Query.execute(sql, fn -> %{"interface" => "http"} end)
    :ok = Web.QueryLog.sync()

    assert [%{"row_count" => 1, "outcome" => "ok"}] =
             Web.QueryLog.table() |> Storage.dump_table() |> Enum.filter(&(&1["sql"] == sql))

    :ok = :erpc.call(peer_node, Web.QueryLog, :sync, [])
    peer_rows = :erpc.call(peer_node, Storage, :dump_table, [Web.QueryLog.table()])
    refute Enum.any?(peer_rows, &(&1["sql"] == sql))
  end
end

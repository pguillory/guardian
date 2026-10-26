defmodule Guardian.Cluster.QueryLogTest do
  # Starts and stops a peer node. While a peer is connected every query in this VM fans
  # out to it, so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false

  setup do
    %{peer_node: peer_node} = context = Guardian.TestCluster.single_peer()
    # Peers run only Storage; give this one a recorder, so a row it recorded would show.
    {:ok, _} =
      :erpc.call(peer_node, GenServer, :start, [
        Guardian.Web.QueryLog,
        [name: Guardian.Web.QueryLog],
        [name: Guardian.Web.QueryLog],
      ])

    context
  end

  test "a query that fans out is recorded once, on the coordinating machine",
       %{peer_node: peer_node} do
    table = "query_log_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    Guardian.Engine.ingest_events(table, [%{"v" => 1}])
    :erpc.call(peer_node, Guardian.Engine, :ingest_events, [table, [%{"v" => 2}]])
    sql = "SELECT count() FROM #{table}"

    assert {:ok, _labels, [[2]]} =
             Guardian.Web.Query.execute(sql, fn -> %{"interface" => "http"} end)

    :ok = Guardian.Web.QueryLog.sync()

    assert [%{"row_count" => 1, "outcome" => "ok"}] =
             Guardian.Web.QueryLog.table()
             |> Guardian.Storage.dump_table()
             |> Enum.filter(&(&1["sql"] == sql))

    :ok = :erpc.call(peer_node, Guardian.Web.QueryLog, :sync, [])

    peer_rows =
      :erpc.call(peer_node, Guardian.Storage, :dump_table, [Guardian.Web.QueryLog.table()])

    refute Enum.any?(peer_rows, &(&1["sql"] == sql))
  end
end

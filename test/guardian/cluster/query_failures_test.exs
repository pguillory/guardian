defmodule Guardian.Cluster.QueryFailuresTest do
  # Starts and stops a peer node. While a peer is connected every query in this VM fans
  # out to it, so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false
  @moduletag :cluster
  import Guardian.Test.Query
  import Guardian.Test.Processes, only: [await_queued_call: 2]

  setup do
    Guardian.Test.Cluster.single_peer()
  end

  test "losing a machine mid-query fails the query instead of dropping its rows",
       %{peer: peer, peer_node: peer_node} do
    table = "query_failures_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    Guardian.Engine.ingest_events(table, Enum.map(1..100, &%{"v" => &1}))

    :erpc.call(peer_node, Guardian.Engine, :ingest_events, [
      table,
      Enum.map(1..100, &%{"v" => &1}),
    ])

    assert run_sql("SELECT count() FROM #{table}") == [[200]]

    statement = resolve_sql("SELECT count() FROM #{table}")

    # Block the peer's scan on its segment, then take the peer away.
    [segment_id] =
      :erpc.call(peer_node, Guardian.Storage, :segment_ids, [table]) |> Enum.to_list()

    {:ok, segment} = :erpc.call(peer_node, Guardian.Storage, :get_segment, [segment_id])
    :ok = :erpc.call(peer_node, :sys, :suspend, [segment])

    task = Task.async(fn -> catch_error(Guardian.Query.run(statement)) end)
    await_queued_call(segment, node: peer_node)
    :peer.stop(peer)

    assert %Guardian.Query.Error{message: message} = Task.await(task, 10_000)
    assert message =~ "disconnected"
  end
end

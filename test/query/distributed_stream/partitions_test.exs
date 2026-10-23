defmodule Query.DistributedStream.PartitionsTest do
  # Starts a peer node. While it is connected every query in this VM fans out to it,
  # so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false

  setup do
    started_distribution = TestCluster.ensure_distributed()
    cookie = Node.get_cookie() |> Atom.to_charlist()

    # No code path: the peer doesn't have Query.DistributedStream, so its partition lookup
    # comes back as {:badrpc, reason}.
    {:ok, peer, node} =
      :peer.start(%{
        name: :"guardian_bare_peer_#{System.unique_integer([:positive])}",
        args: [~c"-setcookie", cookie],
      })

    on_exit(fn ->
      :peer.stop(peer)
      if started_distribution, do: Node.stop()
    end)

    %{node: node}
  end

  test "a node whose partition lookup fails gets no partitions", %{node: node} do
    assert {[_, {:badrpc, _}], []} =
             :rpc.multicall([node(), node], Query.DistributedStream, :node_schedulers, [])

    partitions = Query.DistributedStream.partitions()
    assert partitions == Enum.map(1..System.schedulers_online(), &{node(), &1})

    assert Query.DistributedStream.partitions(concurrency: 2) == [{node(), 1}, {node(), 2}]
  end
end

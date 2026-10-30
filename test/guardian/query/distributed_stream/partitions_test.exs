defmodule Guardian.Query.DistributedStream.PartitionsTest do
  # Starts a peer node. While it is connected every query in this VM fans out to it,
  # so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false
  @moduletag :cluster

  setup do
    started_distribution = Guardian.Test.Cluster.ensure_distributed()
    cookie = Node.get_cookie() |> Atom.to_charlist()

    # No code path: the peer doesn't have Guardian.Query.DistributedStream, so its partition lookup
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
             :rpc.multicall(
               [node(), node],
               Guardian.Query.DistributedStream,
               :node_schedulers,
               []
             )

    partitions = Guardian.Query.DistributedStream.partitions()
    assert partitions == Enum.map(1..System.schedulers_online(), &{node(), &1})

    # Capped at 2, and at the schedulers there are (one under +S1).
    capped = Enum.map(1..min(2, System.schedulers_online()), &{node(), &1})
    assert Guardian.Query.DistributedStream.partitions(concurrency: 2) == capped
    assert Guardian.Query.DistributedStream.partitions(concurrency: 1) == [{node(), 1}]
  end
end

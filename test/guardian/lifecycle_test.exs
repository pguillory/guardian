defmodule Guardian.LifecycleTest do
  # Promises that need a server to stop, tagged :lifecycle and excluded by default; run
  # them with `mix test --include cluster --include lifecycle` before every deploy. Not
  # async: they connect a peer, which every query in this VM then fans out to.
  use ExUnit.Case, async: false

  alias Guardian.Test.Cluster

  @moduletag :lifecycle

  # This calls the application's stop callback on a peer rather than stopping it: peers
  # run Storage, not the whole application, and the flag it sets dies with the peer.
  test "new queries are refused and peers told not ready once the machine begins to stop" do
    %{peer_node: peer_node} = Cluster.single_peer()
    state = make_ref()
    assert :erpc.call(peer_node, Guardian.Application, :prep_stop, [state]) == state

    assert :erpc.call(peer_node, Guardian.Query, :execute, ["select 1"]) ==
             {:error, "this machine is shutting down; retry"}

    refute :erpc.call(peer_node, Guardian.Storage, :ready?, [])
  end

  # Storage stop and start on a peer VM (peers run Storage, not the whole application).
  test "acknowledged rows still in a mutable segment survive a Storage stop and restart" do
    started_distribution = Cluster.ensure_distributed()
    data_root = Cluster.data_root()

    on_exit(fn ->
      File.rm_rf!(data_root)
      if started_distribution, do: Node.stop()
    end)

    table = "lifecycle_#{System.unique_integer([:positive])}"
    rows = for v <- 1..10, do: %{"v" => v}

    {peer, peer_node} = Cluster.start_peer(data_root)
    Cluster.stop_on_exit(peer)

    for row <- rows do
      :ok = :erpc.call(peer_node, Guardian.Storage, :append, [table, row])
    end

    # Still in a partial mutable segment: nothing has been persisted yet.
    assert :erpc.call(peer_node, Guardian.Storage.MutableSegments, :segment_ids, [table]) != []

    Cluster.stop_storage(peer_node)
    :ok = :peer.stop(peer)

    {peer, peer_node} = Cluster.start_peer(data_root)
    Cluster.stop_on_exit(peer)

    assert Enum.sort_by(:erpc.call(peer_node, Guardian.Storage, :dump_table, [table]), & &1["v"]) ==
             rows
  end
end

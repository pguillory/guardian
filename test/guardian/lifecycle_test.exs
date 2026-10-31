defmodule Guardian.LifecycleTest do
  # Promises that need a server to stop, tagged :lifecycle and excluded by default; run
  # them with `mix test --include cluster --include lifecycle` before every deploy. Not
  # async: one test flips the VM-wide stopping flag, and one connects a peer, which every
  # query in this VM then fans out to.
  use ExUnit.Case, async: false

  alias Guardian.Test.Cluster

  @moduletag :lifecycle

  # This calls the application's stop callback rather than stopping the server: the test
  # VM's one Guardian keeps running, so it only flips the stopping flag the callback sets.
  test "new queries are refused and peers told not ready once the machine begins to stop" do
    state = make_ref()
    assert Guardian.Application.prep_stop(state) == state

    try do
      assert Guardian.Query.execute("select 1") ==
               {:error, "this machine is shutting down; retry"}

      refute Guardian.Storage.ready?()
    after
      :persistent_term.erase({Guardian.Application, :stopping})
    end

    assert {:ok, _labels, [[1]]} = Guardian.Query.execute("select 1")
    assert Guardian.Storage.ready?()
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

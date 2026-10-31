defmodule Guardian.Query.HeapLimitClusterTest do
  # Not async: starts a peer node (Guardian.Test.Cluster).
  use ExUnit.Case, async: false

  alias Guardian.Query.DistributedStream

  @moduletag :cluster

  test "a remote worker follows its own node's limit" do
    {_peer, peer_node} = Guardian.Test.Cluster.bare_peer()

    # Low here (the test environment's 16 MiB), production's 256 MiB on the peer, which
    # loads no Mix config: the remote worker finishes what a local one could not.
    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        [1]
        |> DistributedStream.fan_out(fn _ -> {peer_node, 1} end)
        |> DistributedStream.map(&Guardian.Test.DistributedStreamStages.grow_heap/1)
        |> DistributedStream.fan_in()
        |> Enum.to_list()
      end)

    assert Task.await(task, 30_000) == [1_000_000]
  end
end

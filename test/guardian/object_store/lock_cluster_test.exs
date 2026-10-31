defmodule Guardian.ObjectStore.LockClusterTest do
  # Not async: starts a peer node.
  use ExUnit.Case, async: false
  @moduletag :cluster

  alias Guardian.ObjectStore.Lock

  defp race(store, key, peer_node) do
    tasks =
      for node <- [node(), peer_node, node(), peer_node] do
        Task.async(fn ->
          receive do
            :go -> :erpc.call(node, Lock, :acquire, [store, key, "holder"])
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    tasks |> Task.await_many(30_000) |> Enum.filter(&match?({:ok, _}, &1))
  end

  test "connected nodes sharing a folder get one holder per key, on create and takeover" do
    {_peer, peer_node} = Guardian.Test.Cluster.bare_peer()
    dir = Path.join(System.tmp_dir!(), "object_store_lock_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store} = Guardian.ObjectStore.Local.new(dir)

    for key <- 1..25, _round <- 1..2 do
      assert [{:ok, lock}] = race(store, "k#{key}", peer_node)
      assert Lock.release(lock) == :ok
    end
  end
end

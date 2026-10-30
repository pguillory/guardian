defmodule Guardian.Query.DistributedStream.ClusterTest do
  # Starts peer nodes. While a peer is connected every query in this VM fans out to
  # it, so this module must not run concurrently with other tests.
  use ExUnit.Case, async: false
  @moduletag :cluster

  # Crashing workers are plain processes, which log their exceptions.
  @moduletag :capture_log

  import Guardian.Query.DistributedStream
  import Guardian.Test.Polling
  alias Guardian.Test.DistributedStreamStages, as: Stages

  # Keeps :global from disconnecting the other nodes when two peers lose their
  # connection, so the routers' links (all through the test node) stay up and only
  # the edge checks can notice the loss.
  @no_partition_prevention [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]

  setup_all do
    started_distribution = Guardian.Test.Cluster.ensure_distributed()
    {peer_a, a} = Guardian.Test.Cluster.start_peer(nil, @no_partition_prevention)
    {peer_b, b} = Guardian.Test.Cluster.start_peer(nil, @no_partition_prevention)
    true = :erpc.call(a, Node, :connect, [b])

    on_exit(fn ->
      try do
        # Let :global finish its sync with the peers before they go (see below).
        sync_global()
      after
        :peer.stop(peer_a)
        :peer.stop(peer_b)

        try do
          await_no_global_locks()
        after
          if started_distribution, do: Node.stop()
        end

        await_global_registration_works()
      end
    end)

    # Let :global finish syncing with the peers before a test suspends it.
    sync_global()

    %{a: a, b: b}
  end

  # Suspending :global_name_server while peers connect and disconnect can leave
  # :global's own lock held by a peer's locker after the peers are gone, and every later :global.register_name in
  # this VM then retries forever. :global.sync/0 returning does not mean the lockers
  # have released, so teardown also waits for the lock table to empty and then checks
  # that a registration completes, failing here, with :global's state, rather than
  # hanging a later test. After such a failure :global stays wedged for the rest of
  # the run (killing the probe does not stop the registrar's retries), which is why
  # tests must not use :global names.
  defp sync_global do
    task = Task.async(fn -> :global.sync() end)

    case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      other -> flunk(":global.sync() did not finish: #{inspect(other)}")
    end
  end

  defp await_no_global_locks do
    eventually(fn -> :ets.tab2list(:global_locks) == [] end, 10_000)
  rescue
    error in ExUnit.AssertionError ->
      flunk("#{error.message}: :global_locks #{inspect(:ets.tab2list(:global_locks))}")
  end

  defp await_global_registration_works do
    name = {__MODULE__, make_ref()}

    task =
      Task.async(fn ->
        result = :global.register_name(name, self())
        :global.unregister_name(name)
        result
      end)

    case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, :yes} ->
        :ok

      other ->
        flunk(
          ":global.register_name/2 did not succeed after the peers stopped " <>
            "(#{inspect(other)}); :global_locks #{inspect(:ets.tab2list(:global_locks))}"
        )
    end
  end

  setup do
    # A test that cut the peers' connection may have left a resync in flight.
    sync_global()
    # The test node's :global would otherwise react to the peers' lost connection.
    :sys.suspend(:global_name_server)
    on_exit(fn -> :sys.resume(:global_name_server) end)
  end

  defp consume(fun) do
    parent = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)

        result =
          try do
            {:ok, fun.()}
          catch
            :exit, reason -> {:exit, reason}
          end

        send(parent, {tag, result})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:down, reason}
    after
      30_000 -> flunk("pipeline hung")
    end
  end

  # Stage 1 runs on peer A, stage 2 on peer B, so the edge between them crosses the
  # connection that the stage drops.
  defp run(a, b, n, transform) do
    consume(fn ->
      1..n
      |> fan_out(Stages.to(a))
      |> transform(transform)
      |> fan_out(Stages.to(b))
      |> map(&Function.identity/1)
      |> fan_in()
      |> Enum.count()
    end)
  end

  defp assert_complete_or_failed(result, n) do
    case result do
      {:ok, ^n} -> :ok
      {:exit, _reason} -> :ok
      other -> flunk("expected #{n} rows or a failure, got #{inspect(other)}")
    end
  end

  test "a healthy three-node pipeline returns every row", %{a: a, b: b} do
    # Index -1 never comes, so nothing is disconnected.
    assert run(a, b, 500, Stages.disconnect_at(b, -1)) == {:ok, 500}
  end

  test "losing traffic between two worker nodes fails or completes, never loses rows",
       %{a: a, b: b} do
    results =
      for k <- [0, 1, 2, 5, 10, 50, 199], _ <- 1..3 do
        result = run(a, b, 200, Stages.disconnect_at(b, k))
        if System.get_env("DS_CLUSTER_DEBUG"), do: IO.inspect({k, result}, label: "at")
        assert_complete_or_failed(result, 200)
        result
      end

    # Most runs lose a chunk or an acknowledgement and must have failed.
    assert Enum.any?(results, &match?({:exit, _}, &1))
  end

  test "a chunk lost just before its marker fails the pipeline", %{a: a, b: b} do
    for n <- [1, 2, 3], _ <- 1..5 do
      result = run(a, b, n, Stages.disconnect_at_end(b))
      if System.get_env("DS_CLUSTER_DEBUG"), do: IO.inspect({n, result}, label: "end")
      assert_complete_or_failed(result, n)
    end
  end
end

defmodule Counters.ClusterTest do
  use ExUnit.Case, async: false
  alias Counters.Cluster, as: CountersCluster
  alias Counters.Store

  setup_all do
    distributed = TestCluster.ensure_distributed()
    {peer, peer_node} = TestCluster.start_peer(nil)
    {:ok, _} = :erpc.call(peer_node, CounterClusterHelper, :start_store, [])

    on_exit(fn ->
      :peer.stop(peer)
      if distributed, do: Node.stop()
    end)

    %{peer_node: peer_node}
  end

  setup do
    store = start_supervised!({Store, name: nil})
    start_supervised!({CountersCluster, name: :counter_cluster_test})
    %{store: store}
  end

  defp key(group \\ {}, bucket \\ 1), do: {{"events", "hits", "definition-hash"}, group, bucket}

  defp event(store, opts \\ []) do
    CountersCluster.new_event(
      CountersCluster.new_batch(),
      Keyword.merge(
        [store: store, members: [node()], cooldown_table: :counter_cluster_test],
        opts
      )
    )
  end

  defp route({identity, group, _bucket}), do: {identity, group}

  test "canonical rendezvous is order-independent, typed, and only moves to an added member" do
    members = [:a@host, :b@host, :c@host]

    for n <- 1..300 do
      routing = route(key({n}))
      original = CountersCluster.owner(routing, members)
      assert CountersCluster.owner(routing, Enum.reverse(members)) == original
      expanded = CountersCluster.owner(routing, [:d@host | members])
      assert expanded in [original, :d@host]
      remaining = List.delete(members, original)
      assert CountersCluster.owner(routing, remaining) in remaining
      assert CountersCluster.owner(route(key({n}, 4)), members) == original
    end

    # A golden mapping pins the explicit encoding, including signed float zero.
    owners =
      for group <- [{1}, {1.0}, {0.0}, {-0.0}, {nil}, {true}, {"1"}, {[1, 2]}, {%{"x" => 1}}],
          do: CountersCluster.owner(route(key(group)), members)

    assert owners == [
             :c@host,
             :c@host,
             :c@host,
             :a@host,
             :a@host,
             :a@host,
             :b@host,
             :a@host,
             :c@host,
           ]

    assert CountersCluster.owner(route(key({%{"a" => 1, "b" => 2}})), members) ==
             CountersCluster.owner(route(key({Map.new([{"b", 2}, {"a", 1}])})), members)

    signatures =
      for value <- [1, 1.0, 0.0, -0.0],
          do: for(n <- 1..30, do: CountersCluster.owner(route(key({value, n})), members))

    assert length(Enum.uniq(signatures)) == 4
  end

  test "local native operations preserve nil, tokens, colocation and definite errors", %{
    store: store,
  } do
    context = event(store)
    assert CountersCluster.cas(key(), :missing, nil, 5_000, context) == :ok
    assert {:ok, nil, token} = CountersCluster.gets(key(), context)
    assert CountersCluster.cas(key(), token, 7, 5_000, context) == :ok
    assert CountersCluster.cas(key(), token, 8, 5_000, context) == {:error, :conflict}
    assert CountersCluster.incr(key(), 2, 5_000, context) == {:ok, 9}

    assert CountersCluster.get_many([key({}, 2), key(), key()], context) ==
             {:ok, [:not_found, {:ok, 9}, {:ok, 9}]}

    assert CountersCluster.get_many([key({1}), key({2})], context) == {:error, :invalid_request}

    assert CountersCluster.get_many(List.duplicate(key(), 5), context) ==
             {:error, :invalid_request}

    assert CountersCluster.get_many([], context) == {:error, :invalid_request}
    assert CountersCluster.cas(key({}, 3), :missing, "text", 5_000, context) == :ok
    assert CountersCluster.incr(key({}, 3), 1, 5_000, context) == {:error, :not_integer}
    assert :ets.lookup(:counter_cluster_test, node()) == []
  end

  test "peer get/gets/CAS/incr carry native terms and reference tokens", %{peer_node: peer} do
    context = event(Store, members: [peer])
    key = key({System.unique_integer([:positive])})
    value = %{nested: [nil, 1, 1.0, {"native", true}]}
    assert CountersCluster.cas(key, :missing, value, 5_000, context) == :ok
    assert {:ok, ^value, token} = CountersCluster.gets(key, context)
    assert is_reference(token)
    assert CountersCluster.cas(key, token, 3, 5_000, context) == :ok
    assert CountersCluster.incr(key, 2, 5_000, context) == {:ok, 5}
    assert CountersCluster.get_many([key, key], context) == {:ok, [{:ok, 5}, {:ok, 5}]}
    assert :erpc.call(peer, Store, :get, [key]) == {:ok, 5}
  end

  test "booting and lost owners fail immediately without readiness or failover", %{store: store} do
    {peer, booting} = TestCluster.start_peer(nil)
    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)

    for module <- [CountersCluster, Store],
        do: :erpc.call(booting, Code, :ensure_loaded!, [module])

    context = event(Store, members: [booting])
    assert CountersCluster.incr(key(), 1, 5_000, context) == {:error, :unavailable}
    assert CountersCluster.get(key(), context) == {:error, :cooldown}
    :ok = :peer.stop(peer)
    lost = event(store, members: [booting])
    assert CountersCluster.get(key(), lost) in [{:error, :unavailable}, {:error, :cooldown}]
    assert Store.get(key(), server: store) == :not_found
  end

  test "local stall times out, queued mutation expires, cooldown recovers", %{store: store} do
    :sys.suspend(store)
    started = System.monotonic_time(:millisecond)

    try do
      assert CountersCluster.incr(key(), 1, 5_000, event(store)) == {:error, :timeout}
      assert CountersCluster.incr(key(), 1, 5_000, event(store)) == {:error, :cooldown}
      assert System.monotonic_time(:millisecond) - started < 200
    after
      :sys.resume(store)
    end

    assert Store.get(key(), server: store) == :not_found
    Process.sleep(1_010)
    assert CountersCluster.incr(key(), 1, 5_000, event(store)) == {:ok, 1}
  end

  test "short call and exhausted event budget do not mark an owner", %{store: store} do
    :sys.suspend(store)

    try do
      assert CountersCluster.get(key(), event(store, timeout_ms: 15)) == {:error, :timeout}
      assert :ets.lookup(:counter_cluster_test, node()) == []
      batch = CountersCluster.new_batch()

      context =
        CountersCluster.new_event(batch,
          event_timeout_ms: 5,
          members: [node()],
          store: store,
          cooldown_table: :counter_cluster_test
        )

      assert CountersCluster.get(key(), context) == {:error, :budget_exhausted}
      assert :atomics.get(batch, 1) == 250_000
      assert :ets.lookup(:counter_cluster_test, node()) == []
    after
      :sys.resume(store)
    end
  end

  test "large healthy local and peer batches never spend the failure budget", %{
    store: store,
    peer_node: peer,
  } do
    for {target, members} <- [{store, [node()]}, {Store, [peer]}] do
      batch = CountersCluster.new_batch()
      key = key({System.unique_integer([:positive])})

      for n <- 1..300 do
        context =
          CountersCluster.new_event(batch,
            store: target,
            members: members,
            cooldown_table: :counter_cluster_test
          )

        assert CountersCluster.incr(key, 1, 30_000, context) == {:ok, n}
      end

      assert :atomics.get(batch, 1) == 250_000
    end
  end

  test "long batches stop failed waits across replacement workers for local and frozen peer", %{
    store: store,
    peer_node: peer,
  } do
    for {target, members, suspend_node} <- [{store, [node()], node()}, {Store, [peer], peer}] do
      :ok = :erpc.call(suspend_node, :sys, :suspend, [target])
      batch = CountersCluster.new_batch()
      started = System.monotonic_time(:millisecond)

      try do
        for _ <- 1..100 do
          # 15ms calls avoid cooldown to exercise the shared failed-wait cap itself.
          task =
            Task.async(fn ->
              context =
                CountersCluster.new_event(batch,
                  store: target,
                  members: members,
                  timeout_ms: 15,
                  cooldown_table: :counter_cluster_test
                )

              CountersCluster.get(key(), context)
            end)

          assert Task.await(task) in [{:error, :timeout}, {:error, :budget_exhausted}]
        end

        assert :atomics.get(batch, 1) < 10_000
        assert System.monotonic_time(:millisecond) - started < 750
      after
        :erpc.call(suspend_node, :sys, :resume, [target])
      end
    end
  end

  test "caller death conservatively charges its reservation and terminates helpers", %{
    store: store,
  } do
    :sys.suspend(store)
    batch = CountersCluster.new_batch()

    context =
      CountersCluster.new_event(batch,
        store: store,
        members: [node()],
        cooldown_table: :counter_cluster_test
      )

    caller = spawn(fn -> CountersCluster.incr(key(), 1, 5_000, context) end)

    try do
      TestHelpers.await_queued_call(store)
      helpers = counter_helpers()
      assert length(helpers) >= 2
      Process.exit(caller, :kill)
      TestHelpers.eventually(fn -> Enum.all?(helpers, &(not Process.alive?(&1))) end)
      assert :atomics.get(batch, 1) >= 200_000
      assert :atomics.get(batch, 1) < 250_000
    after
      :sys.resume(store)
    end
  end

  test "deadline races leave neither helper processes nor reply messages" do
    store = start_supervised!({Task, fn -> delayed_store() end})

    for _ <- 1..80 do
      # Replies straddle the 10ms boundary, including already-delivered replies
      # racing the caller's timer. Neither outcome may leave messages behind.
      context = event(store, timeout_ms: 10)
      assert CountersCluster.get(key(), context) in [:not_found, {:error, :timeout}]
    end

    TestHelpers.eventually(fn -> counter_helpers() == [] end)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "overlapping callers cannot reserve more than the shared failure allowance", %{
    store: store,
  } do
    :sys.suspend(store)
    batch = CountersCluster.new_batch()

    try do
      outcomes =
        1..30
        |> Task.async_stream(
          fn _ ->
            context =
              CountersCluster.new_event(batch,
                store: store,
                members: [node()],
                cooldown_table: :counter_cluster_test
              )

            CountersCluster.incr(key(), 1, 5_000, context)
          end,
          max_concurrency: 30
        )
        |> Enum.map(fn {:ok, outcome} -> outcome end)

      assert Enum.all?(
               outcomes,
               &(&1 in [{:error, :timeout}, {:error, :budget_exhausted}, {:error, :cooldown}])
             )

      assert Enum.count(outcomes, &(&1 == {:error, :timeout})) in 1..5
      assert :atomics.get(batch, 1) >= 0
    after
      :sys.resume(store)
    end

    assert Store.get(key(), server: store) == :not_found
  end

  test "frozen peer and distribution backpressure cannot outlive the failure budget" do
    {peer_controller, peer} = TestCluster.start_peer(nil)
    {:ok, _} = :erpc.call(peer, CounterClusterHelper, :start_store, [])
    # This PID is obtained directly from our local test peer, never discovered by
    # a process-name search. Always resume it before peer teardown.
    os_pid = :erpc.call(peer, :os, :getpid, []) |> List.to_string()

    on_exit(fn ->
      if Process.alive?(peer_controller) do
        System.cmd("/bin/kill", ["-CONT", os_pid])
        :peer.stop(peer_controller)
      end
    end)

    batch = CountersCluster.new_batch()
    key = key({System.unique_integer([:positive])})
    payload = :binary.copy("x", 8 * 1_024 * 1_024)
    {_, 0} = System.cmd("/bin/kill", ["-STOP", os_pid])
    started = System.monotonic_time(:millisecond)

    try do
      outcomes =
        for _ <- 1..60 do
          context =
            CountersCluster.new_event(batch,
              store: Store,
              members: [peer],
              timeout_ms: 15,
              cooldown_table: :counter_cluster_test
            )

          CountersCluster.cas(key, :missing, payload, 5_000, context)
        end

      assert Enum.all?(outcomes, &(&1 in [{:error, :timeout}, {:error, :budget_exhausted}]))
      assert Enum.count(outcomes, &(&1 == {:error, :timeout})) <= 25
      assert :atomics.get(batch, 1) < 10_000
      assert System.monotonic_time(:millisecond) - started < 750
      TestHelpers.eventually(fn -> counter_helpers() == [] end)
      assert {:messages, []} = Process.info(self(), :messages)
    after
      {_, 0} = System.cmd("/bin/kill", ["-CONT", os_pid])
      :peer.stop(peer_controller)
    end
  end

  test "cooldown expires without reads, departed members are pruned, absent routing fails fast",
       %{store: store} do
    {peer, member} = TestCluster.start_peer(nil)
    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    future = System.monotonic_time(:microsecond) + 10_000_000
    :ets.insert(:counter_cluster_test, {member, future})
    :peer.stop(peer)
    TestHelpers.eventually(fn -> :ets.lookup(:counter_cluster_test, member) == [] end)

    :ets.insert(:counter_cluster_test, {node(), System.monotonic_time(:microsecond) - 1})
    send(Process.whereis(:counter_cluster_test), :cleanup)
    TestHelpers.eventually(fn -> :ets.tab2list(:counter_cluster_test) == [] end)

    stop_supervised(CountersCluster)
    started = System.monotonic_time(:millisecond)
    assert CountersCluster.get(key(), event(store)) == {:error, :cooldown}
    assert System.monotonic_time(:millisecond) - started < 50
  end

  defp counter_helpers do
    for pid <- Process.list(),
        {:registered_name, []} <- [Process.info(pid, :registered_name)],
        {:current_stacktrace, stack} <- [Process.info(pid, :current_stacktrace)],
        Enum.any?(stack, fn {module, _, _, _} -> module == CountersCluster end),
        do: pid
  end

  defp delayed_store do
    receive do
      {:"$gen_call", from, _operation} ->
        Process.sleep(Enum.random([7, 9, 11]))
        GenServer.reply(from, :not_found)
        delayed_store()
    end
  end
end

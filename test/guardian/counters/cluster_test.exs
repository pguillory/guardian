defmodule Guardian.Counters.ClusterTest do
  use ExUnit.Case, async: false
  alias Guardian.Counters.Cluster, as: CountersCluster
  alias Guardian.Counters.Store

  setup_all do
    distributed = Guardian.TestCluster.ensure_distributed()
    {peer, peer_node} = Guardian.TestCluster.start_peer(nil)
    {:ok, _} = :erpc.call(peer_node, Guardian.CounterClusterHelper, :start_store, [])

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

  defp key(group \\ {}, bucket \\ 1) do
    {{"events", "hits", "definition-hash"}, group, bucket}
  end

  defp event(store, opts \\ []) do
    CountersCluster.new_event(
      CountersCluster.new_batch(),
      Keyword.merge(
        [store: store, members: [node()], cooldown_table: :counter_cluster_test],
        opts
      )
    )
  end

  defp route({identity, group, _bucket}) do
    {identity, group}
  end

  defp owned_key(owner, members) do
    group =
      Enum.find(1..10_000, fn n ->
        CountersCluster.owner(route(key({n})), members) == owner
      end)

    key({group})
  end

  test "owner pipelines run concurrently, group every key, and refund healthy waits", %{
    peer_node: peer,
  } do
    local = start_supervised!({Guardian.CounterPipelineProbe, self()})
    {:ok, remote} = :erpc.call(peer, Guardian.CounterPipelineProbe, :start, [self()])

    on_exit(fn ->
      send(local, :release)
      send(remote, :release)
      :erpc.call(peer, GenServer, :stop, [remote])
    end)

    members = [node(), peer]

    ops =
      for owner <- members, bucket <- 1..4, into: %{} do
        {identity, group, _} = owned_key(owner, members)
        {{owner, bucket}, {:get, {identity, group, bucket}}}
      end

    batch = CountersCluster.new_batch()

    task =
      Task.async(fn ->
        context =
          CountersCluster.new_event(batch,
            store: {Guardian.CounterStoreProbe, Guardian.CounterPipelineProbe},
            members: members,
            cooldown_table: :counter_cluster_test
          )

        CountersCluster.batch(ops, context)
      end)

    assert_receive {:pipeline, one, first, first_ops}
    assert_receive {:pipeline, two, second, second_ops}
    assert one != two
    assert length(first_ops) == 4
    assert length(second_ops) == 4
    send(first, :release)
    send(second, :release)

    assert Task.await(task) ==
             Map.new(ops, fn {id, {:get, {_, _, bucket}}} ->
               {id, {:ok, bucket}}
             end)

    assert :atomics.get(batch, 1) == 250_000

    # One available reservation queues the second owner. Its absolute write expiry
    # must be checked after the first owner refunds, not when the round was built.
    [earlier, later] = Enum.sort(members)
    limited = CountersCluster.new_batch()
    :atomics.put(limited, 1, 50_000)
    expiry = System.monotonic_time(:millisecond) + 10

    task =
      Task.async(fn ->
        context =
          CountersCluster.new_event(limited,
            store: {Guardian.CounterStoreProbe, Guardian.CounterPipelineProbe},
            members: members,
            cooldown_table: :counter_cluster_test
          )

        CountersCluster.batch(
          %{
            first: {:get, owned_key(earlier, members)},
            expired: {:incr, owned_key(later, members), 1, {:expires, expiry}},
          },
          context
        )
      end)

    assert_receive {:pipeline, ^earlier, waiting, _}
    Process.sleep(15)
    send(waiting, :release)
    assert Task.await(task) == %{first: {:ok, 1}, expired: {:error, :expired}}
    refute_receive {:pipeline, _, _, _}, 10
    assert :atomics.get(limited, 1) == 50_000

    limited = CountersCluster.new_batch()
    :atomics.put(limited, 1, 20_000)

    task =
      Task.async(fn ->
        context =
          CountersCluster.new_event(limited,
            store: {Guardian.CounterStoreProbe, Guardian.CounterPipelineProbe},
            members: members,
            cooldown_table: :counter_cluster_test
          )

        CountersCluster.batch(
          %{
            first: {:get, owned_key(earlier, members)},
            pending: {:get, owned_key(later, members)},
          },
          context
        )
      end)

    assert_receive {:pipeline, ^earlier, stalled, [_]}
    assert Task.await(task) == %{first: {:error, :timeout}, pending: {:error, :budget_exhausted}}
    send(stalled, :release)
    assert :atomics.get(limited, 1) < 10_000
    refute_receive {:pipeline, _, _, _}, 10
    Guardian.TestHelpers.eventually(fn -> counter_helpers() == [] end)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "pending healthy owners use refunds, even with more than five owners or a spent budget", %{
    peer_node: peer,
  } do
    extra = for _ <- 1..4, do: Guardian.TestCluster.start_peer(nil)
    on_exit(fn -> Enum.each(extra, fn {controller, _} -> :peer.stop(controller) end) end)
    members = [node(), peer | Enum.map(extra, &elem(&1, 1))]
    start_supervised!({Store, name: :counter_pipeline_store}, id: :counter_pipeline_store)

    for member <- tl(members),
        do:
          assert(
            {:ok, _} =
              :erpc.call(member, Guardian.CounterClusterHelper, :start_store, [
                [name: :counter_pipeline_store],
              ])
          )

    for allowance <- [250_000, 50_000] do
      batch = CountersCluster.new_batch()
      :atomics.put(batch, 1, allowance)
      ops = for owner <- members, into: %{}, do: {owner, {:get, owned_key(owner, members)}}

      context =
        CountersCluster.new_event(batch,
          store: :counter_pipeline_store,
          members: members,
          cooldown_table: :counter_cluster_test
        )

      assert CountersCluster.batch(ops, context) == Map.new(members, &{&1, :not_found})
      assert :atomics.get(batch, 1) == allowance
    end

    # A later refund must release pending work while the earliest owner is blocked.
    local = start_supervised!({Guardian.CounterPipelineProbe, self()})

    probes =
      Map.new(tl(members), fn member ->
        {:ok, pid} = :erpc.call(member, Guardian.CounterPipelineProbe, :start, [self()])
        {member, pid}
      end)
      |> Map.put(node(), local)

    on_exit(fn ->
      Enum.each(probes, fn {_, pid} -> send(pid, :release) end)
      :erpc.call(peer, GenServer, :stop, [probes[peer]])
    end)

    ops = Map.new(members, &{&1, {:get, owned_key(&1, members)}})

    task =
      Task.async(fn ->
        context =
          event({Guardian.CounterStoreProbe, Guardian.CounterPipelineProbe}, members: members)

        CountersCluster.batch(ops, context)
      end)

    started =
      for _ <- 1..5 do
        assert_receive {:pipeline, member, _, [_]}
        member
      end

    sorted = Enum.sort(members)
    assert Enum.sort(started) == Enum.take(sorted, 5)
    later = Enum.at(sorted, 4)
    send(probes[later], :release)
    sixth = List.last(sorted)
    assert_receive {:pipeline, ^sixth, _, [_]}
    Enum.each(probes, fn {member, pid} -> if member != later, do: send(pid, :release) end)
    assert Task.await(task) == Map.new(members, &{&1, {:ok, 1}})
    Guardian.TestHelpers.eventually(fn -> counter_helpers() == [] end)
    assert {:messages, []} = Process.info(self(), :messages)
    :erpc.call(peer, GenServer, :stop, [:counter_pipeline_store])
  end

  test "one stalled owner does not lose another owner's results or leak queued mutations", %{
    peer_node: peer,
  } do
    local = start_supervised!({Store, name: :counter_partial_store}, id: :counter_partial_store)

    {:ok, remote} =
      :erpc.call(peer, Guardian.CounterClusterHelper, :start_store, [
        [name: :counter_partial_store],
      ])

    members = [node(), peer]
    local_key = owned_key(node(), members)
    remote_key = owned_key(peer, members)
    pause = :erpc.call(peer, Guardian.CounterStoreProbe, :pause, [remote])

    try do
      context = event(:counter_partial_store, members: members)

      results =
        CountersCluster.batch(
          %{local: {:incr, local_key, 1, 5_000}, remote: {:incr, remote_key, 1, 5_000}},
          context
        )

      assert results == %{local: {:ok, 1}, remote: {:error, :timeout}}
      assert :atomics.get(context.batch, 1) in 200_000..225_000
      assert Store.get(local_key, server: local) == {:ok, 1}
      assert [{^peer, _}] = :ets.lookup(:counter_cluster_test, peer)
      assert :ets.lookup(:counter_cluster_test, node()) == []

      assert CountersCluster.batch(
               %{remote: {:get, remote_key}},
               event(:counter_partial_store, members: members)
             ) == %{remote: {:error, :cooldown}}

      # A translated remote deadline may outlive the caller by transit time.
      Guardian.TestHelpers.await_queued_call(elem(pause, 0), node: peer)
      Process.sleep(55)
    after
      :erpc.call(peer, Guardian.CounterStoreProbe, :resume, [pause])
    end

    assert :erpc.call(peer, Store, :get, [remote_key, [server: remote]]) == :not_found
    :erpc.call(peer, GenServer, :stop, [remote])
    Guardian.TestHelpers.eventually(fn -> counter_helpers() == [] end)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "batch caller death terminates every owner helper and retains reservations", %{
    store: store,
  } do
    pause = Guardian.CounterStoreProbe.pause(store)
    batch = CountersCluster.new_batch()

    caller =
      spawn(fn ->
        context =
          CountersCluster.new_event(batch,
            store: store,
            members: [node()],
            cooldown_table: :counter_cluster_test
          )

        CountersCluster.batch(%{a: {:incr, key(), 1, 5_000}}, context)
      end)

    try do
      Guardian.TestHelpers.await_queued_call(elem(pause, 0))
      helpers = counter_helpers()
      Process.exit(caller, :kill)
      Guardian.TestHelpers.eventually(fn -> Enum.all?(helpers, &(not Process.alive?(&1))) end)
      assert :atomics.get(batch, 1) in 200_000..249_999
      # A dispatched call can survive its caller. Leave it queued past its own deadline.
      Process.sleep(55)
    after
      Guardian.CounterStoreProbe.resume(pause)
    end

    assert Store.get(key(), server: store) == :not_found
  end

  test "malformed pipeline replies are charged consistently and never escape as exceptions" do
    responses = [
      {:ok, []},
      {:ok, [:not_found | :improper]},
      {:error, "private"},
      {:ok, [{:error, "private"}]},
    ]

    for {response, index} <- Enum.with_index(responses) do
      store =
        start_supervised!(
          {Task,
           fn ->
             receive do
               {:"$gen_call", from, _} ->
                 Process.sleep(2)
                 GenServer.reply(from, response)
             end

             Process.sleep(:infinity)
           end},
          id: {:malformed, index}
        )

      context = event({Guardian.CounterStoreProbe, store})

      assert CountersCluster.batch(%{a: {:get, key()}}, context) ==
               %{a: {:error, :invalid_response}}

      assert :atomics.get(context.batch, 1) < 250_000
      assert :ets.lookup(:counter_cluster_test, node()) == []
    end
  end

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
    assert {table, version} = token
    assert is_reference(table) and is_integer(version)
    assert CountersCluster.cas(key, token, 3, 5_000, context) == :ok
    assert CountersCluster.incr(key, 2, 5_000, context) == {:ok, 5}
    assert CountersCluster.get_many([key, key], context) == {:ok, [{:ok, 5}, {:ok, 5}]}
    assert :erpc.call(peer, Store, :get, [key]) == {:ok, 5}
  end

  test "booting and lost owners fail immediately without readiness or failover", %{store: store} do
    {peer, booting} = Guardian.TestCluster.start_peer(nil)
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
    pause = Guardian.CounterStoreProbe.pause(store)
    started = System.monotonic_time(:millisecond)

    try do
      assert CountersCluster.incr(key(), 1, 5_000, event(store)) == {:error, :timeout}
      assert CountersCluster.incr(key(), 1, 5_000, event(store)) == {:error, :cooldown}
      assert System.monotonic_time(:millisecond) - started < 200
    after
      Guardian.CounterStoreProbe.resume(pause)
    end

    assert Store.get(key(), server: store) == :not_found
    Process.sleep(1_010)
    assert CountersCluster.incr(key(), 1, 5_000, event(store)) == {:ok, 1}
  end

  test "short call and exhausted event budget do not mark an owner", %{store: store} do
    pause = Guardian.CounterStoreProbe.pause(store)

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
      Guardian.CounterStoreProbe.resume(pause)
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
      pause = :erpc.call(suspend_node, Guardian.CounterStoreProbe, :pause, [target])
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
        :erpc.call(suspend_node, Guardian.CounterStoreProbe, :resume, [pause])
      end
    end
  end

  test "caller death conservatively charges its reservation and terminates helpers", %{
    store: store,
  } do
    pause = Guardian.CounterStoreProbe.pause(store)
    batch = CountersCluster.new_batch()

    context =
      CountersCluster.new_event(batch,
        store: store,
        members: [node()],
        cooldown_table: :counter_cluster_test
      )

    caller = spawn(fn -> CountersCluster.incr(key(), 1, 5_000, context) end)

    try do
      Guardian.TestHelpers.await_queued_call(elem(pause, 0))
      helpers = counter_helpers()
      assert length(helpers) >= 2
      Process.exit(caller, :kill)
      Guardian.TestHelpers.eventually(fn -> Enum.all?(helpers, &(not Process.alive?(&1))) end)
      assert :atomics.get(batch, 1) >= 200_000
      assert :atomics.get(batch, 1) < 250_000
    after
      Guardian.CounterStoreProbe.resume(pause)
    end
  end

  test "deadline races leave neither helper processes nor reply messages" do
    store = start_supervised!({Task, fn -> delayed_store() end})

    for _ <- 1..80 do
      # Replies straddle the 10ms boundary, including already-delivered replies
      # racing the caller's timer. Neither outcome may leave messages behind.
      context = event({Guardian.CounterStoreProbe, store}, timeout_ms: 10)
      assert CountersCluster.get(key(), context) in [:not_found, {:error, :timeout}]
    end

    Guardian.TestHelpers.eventually(fn -> counter_helpers() == [] end)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "overlapping callers cannot reserve more than the shared failure allowance", %{
    store: store,
  } do
    pause = Guardian.CounterStoreProbe.pause(store)
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
      Guardian.CounterStoreProbe.resume(pause)
    end

    assert Store.get(key(), server: store) == :not_found
  end

  test "frozen peer and distribution backpressure cannot outlive the failure budget" do
    {peer_controller, peer} = Guardian.TestCluster.start_peer(nil)
    {:ok, _} = :erpc.call(peer, Guardian.CounterClusterHelper, :start_store, [])
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
      Guardian.TestHelpers.eventually(fn -> counter_helpers() == [] end)
      assert {:messages, []} = Process.info(self(), :messages)
    after
      {_, 0} = System.cmd("/bin/kill", ["-CONT", os_pid])
      :peer.stop(peer_controller)
    end
  end

  test "cooldown expires without reads, departed members are pruned, absent routing fails fast",
       %{store: store} do
    {peer, member} = Guardian.TestCluster.start_peer(nil)
    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    future = System.monotonic_time(:microsecond) + 10_000_000
    :ets.insert(:counter_cluster_test, {member, future})
    :peer.stop(peer)
    Guardian.TestHelpers.eventually(fn -> :ets.lookup(:counter_cluster_test, member) == [] end)

    :ets.insert(:counter_cluster_test, {node(), System.monotonic_time(:microsecond) - 1})
    send(Process.whereis(:counter_cluster_test), :cleanup)
    Guardian.TestHelpers.eventually(fn -> :ets.tab2list(:counter_cluster_test) == [] end)

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

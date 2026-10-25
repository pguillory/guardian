defmodule Guardian.Counters.ClientTest do
  use ExUnit.Case, async: false
  alias Guardian.Counters.{Budget, Client, Transport}
  alias Guardian.Counters.Store

  setup_all do
    distributed = Guardian.TestCluster.ensure_distributed()
    {peer, peer_node} = Guardian.TestCluster.start_peer(nil)

    on_exit(fn ->
      :peer.stop(peer)
      if distributed, do: Node.stop()
    end)

    {:ok, _} = :erpc.call(peer_node, Guardian.CounterClientHelper, :start_store, [])
    Guardian.CounterClientHelper.await_ready(peer_node)
    %{peer_node: peer_node}
  end

  setup do
    store = start_supervised!({Store, name: nil})
    start_supervised!({Budget, name: :counter_client_test})
    %{store: store}
  end

  defp key(group \\ {}, bucket \\ 1) do
    {{"events", "hits", "definition-hash"}, group, bucket}
  end

  defp event(store, opts \\ []) do
    Client.new_event(
      Client.new_batch(),
      Keyword.merge(
        [store: store, members: [node()], cooldown_table: :counter_client_test],
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
        Transport.owner(route(key({n})), members) == owner
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

    batch = Client.new_batch()

    task =
      Task.async(fn ->
        context =
          Client.new_event(batch,
            store: {Guardian.CounterStoreProbe, Guardian.CounterPipelineProbe},
            members: members,
            cooldown_table: :counter_client_test
          )

        Client.batch(ops, context)
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
    limited = Client.new_batch()
    :atomics.put(limited, 1, 50_000)
    expiry = System.monotonic_time(:millisecond) + 10

    task =
      Task.async(fn ->
        context =
          Client.new_event(limited,
            store: {Guardian.CounterStoreProbe, Guardian.CounterPipelineProbe},
            members: members,
            cooldown_table: :counter_client_test
          )

        Client.batch(
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

    limited = Client.new_batch()
    :atomics.put(limited, 1, 20_000)

    task =
      Task.async(fn ->
        context =
          Client.new_event(limited,
            store: {Guardian.CounterStoreProbe, Guardian.CounterPipelineProbe},
            members: members,
            cooldown_table: :counter_client_test
          )

        Client.batch(
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
              :erpc.call(member, Guardian.CounterClientHelper, :start_store, [
                [name: :counter_pipeline_store],
              ])
          )

    Guardian.CounterClientHelper.await_ready(tl(members), :counter_pipeline_store)

    for allowance <- [250_000, 50_000] do
      batch = Client.new_batch()
      :atomics.put(batch, 1, allowance)
      ops = for owner <- members, into: %{}, do: {owner, {:get, owned_key(owner, members)}}

      context =
        Client.new_event(batch,
          store: :counter_pipeline_store,
          members: members,
          cooldown_table: :counter_client_test
        )

      assert Client.batch(ops, context) == Map.new(members, &{&1, :not_found})
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

        Client.batch(ops, context)
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
      :erpc.call(peer, Guardian.CounterClientHelper, :start_store, [
        [name: :counter_partial_store],
      ])

    members = [node(), peer]
    local_key = owned_key(node(), members)
    remote_key = owned_key(peer, members)
    pause = :erpc.call(peer, Guardian.CounterStoreProbe, :pause, [remote])

    try do
      context = event(:counter_partial_store, members: members)

      results =
        Client.batch(
          %{local: {:incr, local_key, 1, 5_000}, remote: {:incr, remote_key, 1, 5_000}},
          context
        )

      assert results == %{local: {:ok, 1}, remote: {:error, :timeout}}
      assert :atomics.get(context.batch, 1) in 200_000..225_000
      assert Store.get(local_key, server: local) == {:ok, 1}
      assert [{^peer, _}] = :ets.lookup(:counter_client_test, peer)
      assert :ets.lookup(:counter_client_test, node()) == []

      assert Client.batch(
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
    batch = Client.new_batch()

    caller =
      spawn(fn ->
        context =
          Client.new_event(batch,
            store: store,
            members: [node()],
            cooldown_table: :counter_client_test
          )

        Client.batch(%{a: {:incr, key(), 1, 5_000}}, context)
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

  test "malformed operations and routing keys are refused before dispatch", %{store: store} do
    context = event(store)

    for operation <- [nil, {:unsupported, key()}, {:get, :bad_key}, {:get, {nil, {}, 1}}] do
      assert Client.batch(%{one: operation}, context) ==
               %{one: {:error, :invalid_request}}
    end

    assert :atomics.get(context.batch, 1) == 250_000
    assert :ets.lookup(:counter_client_test, node()) == []
  end

  test "the remote endpoint refuses scalar operations", %{store: store} do
    for operation <- [{:get, key()}, {:incr, key(), 1, 5_000}] do
      assert Transport.remote_operation(operation, store, 50) == {:error, :invalid_request}
    end

    assert Store.get(key(), server: store) == :not_found
  end

  test "the renamed remote endpoint preserves batch replies and duration bounds", %{
    peer_node: peer,
  } do
    remote_key = key({"remote-endpoint"})

    assert :erpc.call(peer, Transport, :remote_operation, [
             {:batch, [{:get, remote_key}]},
             Store,
             50,
           ]) ==
             {:ok, [:not_found]}

    for duration <- [0, -1, 51, 1.0, nil] do
      assert :erpc.call(peer, Transport, :remote_operation, [
               {:batch, [{:incr, remote_key, 1, 1_000}]},
               Store,
               duration,
             ]) == {:error, :invalid_request}
    end

    assert :erpc.call(peer, Store, :get, [remote_key]) == :not_found
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

      assert Client.batch(%{a: {:get, key()}}, context) ==
               %{a: {:error, :invalid_response}}

      assert :atomics.get(context.batch, 1) < 250_000
      assert :ets.lookup(:counter_client_test, node()) == []
    end
  end

  test "phash2 rendezvous is order-independent and only moves to an added member" do
    members = [:a@host, :b@host, :c@host]

    for n <- 1..300 do
      routing = route(key({n}))
      original = Transport.owner(routing, members)
      assert Transport.owner(routing, Enum.reverse(members)) == original
      expanded = Transport.owner(routing, [:d@host | members])
      assert expanded in [original, :d@host]
      remaining = List.delete(members, original)
      assert Transport.owner(routing, remaining) in remaining

      for removed <- remaining do
        assert Transport.owner(routing, List.delete(members, removed)) == original
      end

      assert Transport.owner(route(key({n}, 4)), members) == original
    end

    # Golden owners pin the 32-bit phash2 score, including shared signed-zero routing.
    owners =
      for group <- [{1}, {1.0}, {0.0}, {-0.0}, {nil}, {true}, {"1"}, {[1, 2]}, {%{"x" => 1}}],
          do: Transport.owner(route(key(group)), members)

    assert owners == [
             :c@host,
             :a@host,
             :b@host,
             :b@host,
             :c@host,
             :c@host,
             :c@host,
             :a@host,
             :c@host,
           ]

    assert Transport.owner(route(key({%{"a" => 1, "b" => 2}})), members) ==
             Transport.owner(route(key({Map.new([{"b", 2}, {"a", 1}])})), members)

    [integer, float, positive_zero, negative_zero] =
      for value <- [1, 1.0, 0.0, -0.0],
          do: for(n <- 1..30, do: Transport.owner(route(key({value, n})), members))

    assert length(Enum.uniq([integer, float, positive_zero])) == 3
    assert positive_zero == negative_zero
  end

  test "atom group terms route and store", %{store: store} do
    context = event(store)
    atom_key = key({:group})

    assert batch_one({:incr, atom_key, 1, 5_000}, context) == {:ok, 1}
    assert Store.get(atom_key, server: store) == {:ok, 1}
  end

  test "local native operations preserve nil, tokens, colocation and definite errors", %{
    store: store,
  } do
    context = event(store)
    assert batch_one({:cas, key(), :missing, nil, 5_000}, context) == :ok
    assert {:ok, nil, token} = batch_one({:gets, key()}, context)
    assert batch_one({:cas, key(), token, 7, 5_000}, context) == :ok
    assert batch_one({:cas, key(), token, 8, 5_000}, context) == {:error, :conflict}
    assert batch_one({:incr, key(), 2, 5_000}, context) == {:ok, 9}

    assert Client.batch(
             %{missing: {:get, key({}, 2)}, present: {:get, key()}},
             context
           ) == %{missing: :not_found, present: {:ok, 9}}

    assert batch_one({:cas, key({}, 3), :missing, "text", 5_000}, context) == :ok
    assert batch_one({:incr, key({}, 3), 1, 5_000}, context) == {:error, :not_integer}
    assert :ets.lookup(:counter_client_test, node()) == []
  end

  test "successful error-shaped values remain opaque through local and peer pipelines", %{
    store: store,
    peer_node: peer,
  } do
    for {server, members} <- [{store, [node()]}, {Store, [peer]}],
        value <- [{:error, :unavailable}, [{:error, :timeout}, {:error, :unavailable}]] do
      context = event(server, members: members)
      stored_key = key({System.unique_integer([:positive])})
      assert batch_one({:cas, stored_key, :missing, value, 5_000}, context) == :ok
      assert batch_one({:get, stored_key}, context) == {:ok, value}
      assert {:ok, ^value, _token} = batch_one({:gets, stored_key}, context)
      assert :atomics.get(context.batch, 1) == 250_000
      assert :ets.tab2list(:counter_client_test) == []
    end
  end

  test "peer get/gets/CAS/incr carry native terms and reference tokens", %{peer_node: peer} do
    Guardian.CounterBudgetHelper.relax([peer])
    context = event(Store, members: [peer])
    key = key({System.unique_integer([:positive])})
    value = %{nested: [nil, 1, 1.0, {"native", true}]}
    assert batch_one({:cas, key, :missing, value, 5_000}, context) == :ok
    assert {:ok, ^value, token} = batch_one({:gets, key}, context)
    assert {table, version} = token
    assert is_reference(table) and is_integer(version)
    assert batch_one({:cas, key, token, 3, 5_000}, context) == :ok
    assert batch_one({:incr, key, 2, 5_000}, context) == {:ok, 5}

    assert Client.batch(%{one: {:get, key}, two: {:get, key}}, context) ==
             %{one: {:ok, 5}, two: {:ok, 5}}

    assert :erpc.call(peer, Store, :get, [key]) == {:ok, 5}
  end

  test "shared aggregate states survive ETF, local ETS and peer ETS with further merges", %{
    peer_node: peer,
    store: store,
  } do
    alias Guardian.Aggregation

    for {name, arity} = operator <- Aggregation.names_and_arities() do
      aggregation = Aggregation.fetch!(name)
      args = &Guardian.AggregationTestHelper.args(name, arity, &1)
      empty = Aggregation.empty(aggregation)
      delta = Aggregation.start(aggregation, args.(-0.0))

      populated =
        Enum.reduce([nil, 2, 3.5, "x", [1, nil]], empty, fn value, acc ->
          Aggregation.merge(
            aggregation,
            acc,
            Aggregation.start(aggregation, args.(value))
          )
        end)

      extra =
        case operator do
          {name, _} when name in ["sum", "avg"] -> [:overflow]
          {"count", _} -> [Guardian.Query.Numeric.max_int() + 1]
          _ -> []
        end

      for state <- [empty, populated, delta | extra],
          {owner, server} <- [{node(), store}, {peer, Store}] do
        encoded = :erlang.term_to_binary(state)
        assert :erlang.term_to_binary(:erlang.binary_to_term(encoded, [:safe])) == encoded
        key = key({System.unique_integer([:positive])})
        opts = [server: server, timeout: 5_000]

        assert :erpc.call(owner, Store, :cas, [key, :missing, state, 5_000, opts]) == :ok
        assert {:ok, restored, token} = :erpc.call(owner, Store, :gets, [key, opts])
        assert :erlang.term_to_binary(restored) == encoded
        unchanged = :erpc.call(owner, Aggregation, :merge, [aggregation, restored, empty])
        assert :erlang.term_to_binary(unchanged) == encoded
        merged = :erpc.call(owner, Aggregation, :merge, [aggregation, restored, delta])
        expected = Aggregation.merge(aggregation, state, delta)
        assert :erlang.term_to_binary(merged) == :erlang.term_to_binary(expected)
        assert :erpc.call(owner, Store, :cas, [key, token, merged, 5_000, opts]) == :ok
        assert {:ok, reread} = :erpc.call(owner, Store, :get, [key, opts])
        assert :erlang.term_to_binary(reread) == :erlang.term_to_binary(expected)

        assert :erpc.call(owner, Aggregation, :finish, [aggregation, reread]) ===
                 Aggregation.finish(aggregation, expected)
      end
    end
  end

  test "booting and lost owners fail immediately without readiness or failover", %{store: store} do
    {peer, booting} = Guardian.TestCluster.start_peer(nil)
    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)

    for module <- [Transport, Store],
        do: :erpc.call(booting, Code, :ensure_loaded!, [module])

    context = event(Store, members: [booting])
    assert batch_one({:incr, key(), 1, 5_000}, context) == {:error, :unavailable}
    assert batch_one({:get, key()}, context) == {:error, :cooldown}
    :ok = :peer.stop(peer)
    lost = event(store, members: [booting])
    assert batch_one({:get, key()}, lost) in [{:error, :unavailable}, {:error, :cooldown}]
    assert Store.get(key(), server: store) == :not_found
  end

  test "local stall times out, queued mutation expires, cooldown recovers", %{store: store} do
    pause = Guardian.CounterStoreProbe.pause(store)
    started = System.monotonic_time(:millisecond)

    try do
      assert batch_one({:incr, key(), 1, 5_000}, event(store)) == {:error, :timeout}
      assert batch_one({:incr, key(), 1, 5_000}, event(store)) == {:error, :cooldown}
      assert System.monotonic_time(:millisecond) - started < 200
    after
      Guardian.CounterStoreProbe.resume(pause)
    end

    assert Store.get(key(), server: store) == :not_found
    Process.sleep(1_010)
    assert batch_one({:incr, key(), 1, 5_000}, event(store)) == {:ok, 1}
  end

  test "short call and exhausted event budget do not mark an owner", %{store: store} do
    pause = Guardian.CounterStoreProbe.pause(store)

    try do
      assert batch_one({:get, key()}, event(store, timeout_ms: 15)) == {:error, :timeout}
      assert :ets.lookup(:counter_client_test, node()) == []
      batch = Client.new_batch()

      context =
        Client.new_event(batch,
          event_timeout_ms: 5,
          members: [node()],
          store: store,
          cooldown_table: :counter_client_test
        )

      assert batch_one({:get, key()}, context) == {:error, :budget_exhausted}
      assert :atomics.get(batch, 1) == 250_000
      assert :ets.lookup(:counter_client_test, node()) == []
    after
      Guardian.CounterStoreProbe.resume(pause)
    end
  end

  test "large healthy local and peer batches never spend the failure budget", %{
    store: store,
    peer_node: peer,
  } do
    for {target, members} <- [{store, [node()]}, {Store, [peer]}] do
      batch = Client.new_batch()
      key = key({System.unique_integer([:positive])})

      for n <- 1..300 do
        context =
          Client.new_event(batch,
            store: target,
            members: members,
            cooldown_table: :counter_client_test
          )

        assert batch_one({:incr, key, 1, 30_000}, context) == {:ok, n}
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
      batch = Client.new_batch()
      started = System.monotonic_time(:millisecond)

      try do
        for _ <- 1..100 do
          # 15ms calls avoid cooldown to exercise the shared failed-wait cap itself.
          task =
            Task.async(fn ->
              context =
                Client.new_event(batch,
                  store: target,
                  members: members,
                  timeout_ms: 15,
                  cooldown_table: :counter_client_test
                )

              batch_one({:get, key()}, context)
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
    batch = Client.new_batch()

    context =
      Client.new_event(batch,
        store: store,
        members: [node()],
        cooldown_table: :counter_client_test
      )

    caller = spawn(fn -> batch_one({:incr, key(), 1, 5_000}, context) end)

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
      assert batch_one({:get, key()}, context) in [:not_found, {:error, :timeout}]
    end

    Guardian.TestHelpers.eventually(fn -> counter_helpers() == [] end)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "overlapping callers cannot reserve more than the shared failure allowance", %{
    store: store,
  } do
    pause = Guardian.CounterStoreProbe.pause(store)
    batch = Client.new_batch()

    try do
      outcomes =
        1..30
        |> Task.async_stream(
          fn _ ->
            context =
              Client.new_event(batch,
                store: store,
                members: [node()],
                cooldown_table: :counter_client_test
              )

            batch_one({:incr, key(), 1, 5_000}, context)
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
    {:ok, _} = :erpc.call(peer, Guardian.CounterClientHelper, :start_store, [])
    # This PID is obtained directly from our local test peer, never discovered by
    # a process-name search. Always resume it before peer teardown.
    os_pid = :erpc.call(peer, :os, :getpid, []) |> List.to_string()

    on_exit(fn ->
      if Process.alive?(peer_controller) do
        System.cmd("/bin/kill", ["-CONT", os_pid])
        :peer.stop(peer_controller)
      end
    end)

    batch = Client.new_batch()
    key = key({System.unique_integer([:positive])})
    payload = :binary.copy("x", 8 * 1_024 * 1_024)
    {_, 0} = System.cmd("/bin/kill", ["-STOP", os_pid])
    started = System.monotonic_time(:millisecond)

    try do
      outcomes =
        for _ <- 1..60 do
          context =
            Client.new_event(batch,
              store: Store,
              members: [peer],
              timeout_ms: 15,
              cooldown_table: :counter_client_test
            )

          batch_one({:cas, key, :missing, payload, 5_000}, context)
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
    :ets.insert(:counter_client_test, {member, future})
    :peer.stop(peer)
    Guardian.TestHelpers.eventually(fn -> :ets.lookup(:counter_client_test, member) == [] end)

    :ets.insert(:counter_client_test, {node(), System.monotonic_time(:microsecond) - 1})
    send(Process.whereis(:counter_client_test), :cleanup)
    Guardian.TestHelpers.eventually(fn -> :ets.tab2list(:counter_client_test) == [] end)

    stop_supervised(Budget)
    started = System.monotonic_time(:millisecond)
    assert batch_one({:get, key()}, event(store)) == {:error, :cooldown}
    assert System.monotonic_time(:millisecond) - started < 50
  end

  defp batch_one(operation, event) do
    Client.batch(%{one: operation}, event).one
  end

  defp counter_helpers do
    for pid <- Process.list(),
        {:registered_name, []} <- [Process.info(pid, :registered_name)],
        {:current_stacktrace, stack} <- [Process.info(pid, :current_stacktrace)],
        Enum.any?(stack, fn {module, _, _, _} -> module == Transport end),
        do: pid
  end

  defp delayed_store do
    receive do
      {:"$gen_call", from, {:operation, _deadline, {:batch, operations}}} ->
        Process.sleep(Enum.random([7, 9, 11]))
        GenServer.reply(from, {:ok, Enum.map(operations, fn _ -> :not_found end)})
        delayed_store()
    end
  end
end

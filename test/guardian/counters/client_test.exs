defmodule Guardian.Counters.ClientTest do
  use ExUnit.Case, async: false
  alias Guardian.Counters.{Budget, Client, Execution, Machine, Transport}
  alias Guardian.Counters.Store
  alias Guardian.Test.Counters.Budget, as: CounterBudgetHelper

  setup_all do
    distributed = Guardian.Test.Cluster.ensure_distributed()
    {peer, peer_node} = Guardian.Test.Cluster.start_peer(nil)

    on_exit(fn ->
      :peer.stop(peer)
      if distributed, do: Node.stop()
    end)

    {:ok, _} = :erpc.call(peer_node, Guardian.Test.Counters.Client, :start_store, [])
    Guardian.Test.Counters.Client.await_ready(peer_node)
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
    event(Client.new_batch(), store, opts)
  end

  defp event(batch, store, opts) do
    Client.new_event(
      batch,
      Keyword.merge(
        [store: store, members: [node()], cooldown_table: :counter_client_test],
        opts
      )
    )
  end

  # One round through route/2 and dispatch/2 in Counters.Execution's round loop,
  # each operation a machine that finishes with its response; keyed like the
  # operations map, which sets the input order. Using the real round loop (the
  # module above Client) avoids re-implementing its routing, grouping and scatter.
  # Machine.new/3 rejects a nil operation, so tests route nil directly.
  defp batch(operations, context) do
    {ids, ops} = Enum.unzip(operations)

    responses =
      ops
      |> Enum.map(&Machine.new(&1, nil, fn _op, response, _state -> {:done, response} end))
      |> Execution.run_state_machines(context)
      |> Enum.map(& &1.result)

    ids |> Enum.zip(responses) |> Map.new()
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
    local = start_supervised!({Guardian.Test.Counters.PipelineProbe, self()})
    {:ok, remote} = :erpc.call(peer, Guardian.Test.Counters.PipelineProbe, :start, [self()])

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

    # Scaled budget (Guardian.Test.Counters.Budget): both held owners must dispatch concurrently
    # and wait for the test's release, which under host load can outlast a 50 ms call
    # deadline. A 1 s unit with an allowance of five units keeps both reservations
    # concurrent, as production's 50 ms of 250 ms does.
    restore_scaled =
      CounterBudgetHelper.scale([peer])

    five = CounterBudgetHelper.allowance_us(5)
    batch = CounterBudgetHelper.batch(5)

    task =
      Task.async(fn ->
        context =
          event(batch, {Guardian.Test.Counters.ProbeStore, Guardian.Test.Counters.PipelineProbe},
            members: members
          )

        batch(ops, context)
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

    assert CounterBudgetHelper.remaining_us(batch) == five
    restore_scaled.()

    # One available reservation queues the second owner. Its absolute write expiry
    # must be checked after the first owner refunds, not when the round was built.
    # Relaxed budgets let the first owner's call reserve the batch's whole 250 ms
    # allowance, so the 15 ms hold below is far less likely to time out under host load. The expired
    # owner then reserves and refunds without dispatching, returning the full allowance.
    restore_budgets = CounterBudgetHelper.relax([peer])
    [earlier, later] = Enum.sort(members)
    limited = Client.new_batch()
    expiry = System.monotonic_time(:millisecond) + 10

    task =
      Task.async(fn ->
        context =
          event(
            limited,
            {Guardian.Test.Counters.ProbeStore, Guardian.Test.Counters.PipelineProbe},
            members: members
          )

        batch(
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
    assert CounterBudgetHelper.remaining_us(limited) == 250_000
    restore_budgets.()

    # 20 ms is above the 10 ms minimum but below a whole 50 ms call reservation.
    limited = CounterBudgetHelper.batch(0.4)

    task =
      Task.async(fn ->
        context =
          event(
            limited,
            {Guardian.Test.Counters.ProbeStore, Guardian.Test.Counters.PipelineProbe},
            members: members
          )

        batch(
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
    assert CounterBudgetHelper.remaining_us(limited) < 10_000
    refute_receive {:pipeline, _, _, _}, 10
    Guardian.Test.Polling.eventually(fn -> counter_helpers() == [] end)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "pending healthy owners use refunds, even with more than five owners or a spent budget", %{
    peer_node: peer,
  } do
    extra = for _ <- 1..4, do: Guardian.Test.Cluster.start_peer(nil)
    on_exit(fn -> Enum.each(extra, fn {controller, _} -> :peer.stop(controller) end) end)
    members = [node(), peer | Enum.map(extra, &elem(&1, 1))]
    start_supervised!({Store, name: :counter_pipeline_store}, id: :counter_pipeline_store)

    for member <- tl(members),
        do:
          assert(
            {:ok, _} =
              :erpc.call(member, Guardian.Test.Counters.Client, :start_store, [
                [name: :counter_pipeline_store],
              ])
          )

    Guardian.Test.Counters.Client.await_ready(tl(members), :counter_pipeline_store)

    # Production fits five 50 ms reservations in a 250 ms allowance, but 50 ms is also
    # each call's wall-clock deadline, which host load can exceed. Scale the unit: a
    # 1 s operation budget with allowances of five units and one unit makes every
    # reservation decision the same, with a 1 s deadline per held call.
    CounterBudgetHelper.scale(tl(members))

    for multiple <- [5, 1] do
      allowance = CounterBudgetHelper.allowance_us(multiple)
      batch = CounterBudgetHelper.batch(multiple)
      ops = for owner <- members, into: %{}, do: {owner, {:get, owned_key(owner, members)}}

      context =
        event(batch, :counter_pipeline_store, members: members)

      assert batch(ops, context) == Map.new(members, &{&1, :not_found})
      assert CounterBudgetHelper.remaining_us(batch) == allowance
    end

    # A later refund must release pending work while the earliest owner is blocked.
    local = start_supervised!({Guardian.Test.Counters.PipelineProbe, self()})

    probes =
      Map.new(tl(members), fn member ->
        {:ok, pid} = :erpc.call(member, Guardian.Test.Counters.PipelineProbe, :start, [self()])
        {member, pid}
      end)
      |> Map.put(node(), local)

    on_exit(fn ->
      Enum.each(probes, fn {_, pid} -> send(pid, :release) end)
      :erpc.call(peer, GenServer, :stop, [probes[peer]])
    end)

    ops = Map.new(members, &{&1, {:get, owned_key(&1, members)}})
    batch = CounterBudgetHelper.batch(5)

    task =
      Task.async(fn ->
        context =
          event(batch, {Guardian.Test.Counters.ProbeStore, Guardian.Test.Counters.PipelineProbe},
            members: members
          )

        batch(ops, context)
      end)

    started =
      for _ <- 1..5 do
        assert_receive {:pipeline, member, _, [_]}
        member
      end

    sorted = Enum.sort(members)
    assert Enum.sort(started) == Enum.take(sorted, 5)
    sixth = List.last(sorted)
    # Five reservations spend the whole allowance, so the sixth owner waits.
    assert CounterBudgetHelper.remaining_us(batch) == 0
    refute_receive {:pipeline, ^sixth, _, _}, 20
    later = Enum.at(sorted, 4)
    send(probes[later], :release)
    assert_receive {:pipeline, ^sixth, _, [_]}
    Enum.each(probes, fn {member, pid} -> if member != later, do: send(pid, :release) end)
    assert Task.await(task) == Map.new(members, &{&1, {:ok, 1}})
    Guardian.Test.Polling.eventually(fn -> counter_helpers() == [] end)
    assert {:messages, []} = Process.info(self(), :messages)
    :erpc.call(peer, GenServer, :stop, [:counter_pipeline_store])
  end

  test "one stalled owner does not lose another owner's results or leak queued mutations", %{
    peer_node: peer,
  } do
    local = start_supervised!({Store, name: :counter_partial_store}, id: :counter_partial_store)

    {:ok, remote} =
      :erpc.call(peer, Guardian.Test.Counters.Client, :start_store, [
        [name: :counter_partial_store],
      ])

    members = [node(), peer]
    local_key = owned_key(node(), members)
    remote_key = owned_key(peer, members)
    pause = :erpc.call(peer, Guardian.Test.Counters.StorePause, :pause, [remote])

    try do
      context = event(:counter_partial_store, members: members)

      results =
        batch(
          %{local: {:incr, local_key, 1, 5_000}, remote: {:incr, remote_key, 1, 5_000}},
          context
        )

      assert results == %{local: {:ok, 1}, remote: {:error, :timeout}}
      assert CounterBudgetHelper.remaining_us(context.batch) in 200_000..225_000
      assert Store.get(local_key, server: local) == {:ok, 1}
      assert [{^peer, _}] = :ets.lookup(:counter_client_test, peer)
      assert :ets.lookup(:counter_client_test, node()) == []

      assert batch(
               %{remote: {:get, remote_key}},
               event(:counter_partial_store, members: members)
             ) == %{remote: {:error, :cooldown}}

      # A translated remote deadline may outlive the caller by transit time.
      Guardian.Test.Processes.await_queued_call(elem(pause, 0), node: peer)
      Process.sleep(55)
    after
      :erpc.call(peer, Guardian.Test.Counters.StorePause, :resume, [pause])
    end

    assert :erpc.call(peer, Store, :get, [remote_key, [server: remote]]) == :not_found
    :erpc.call(peer, GenServer, :stop, [remote])
    Guardian.Test.Polling.eventually(fn -> counter_helpers() == [] end)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "batch caller death terminates every owner helper and retains reservations", %{
    store: store,
  } do
    # Scaled budget (Guardian.Test.Counters.Budget): under load the production 50 ms call could
    # time out before the test sees its helpers and kills the caller. A 1 s unit with an
    # allowance of five units keeps the reservation decision and its retention the same.
    CounterBudgetHelper.scale()
    unit = CounterBudgetHelper.allowance_us(1)
    pause = Guardian.Test.Counters.StorePause.pause(store)
    batch = CounterBudgetHelper.batch(5)

    caller =
      spawn(fn ->
        context =
          event(batch, store, members: [node()])

        batch(%{a: {:incr, key(), 1, 5_000}}, context)
      end)

    try do
      Guardian.Test.Processes.await_queued_call(elem(pause, 0))
      helpers = counter_helpers()
      assert length(helpers) >= 2
      Process.exit(caller, :kill)
      Guardian.Test.Polling.eventually(fn -> Enum.all?(helpers, &(not Process.alive?(&1))) end)
      assert CounterBudgetHelper.remaining_us(batch) in (4 * unit)..(5 * unit - 1)
      # A dispatched call can survive its caller. Leave it queued past its own deadline.
      Process.sleep(Guardian.Counters.Context.operation_ms() + 5)
    after
      Guardian.Test.Counters.StorePause.resume(pause)
    end

    assert Store.get(key(), server: store) == :not_found
  end

  test "malformed operations and routing keys are refused before dispatch", %{store: store} do
    context = event(store)

    malformed_expiries =
      for expiry <- [nil, :bad, "bad", [], %{}, {}, 0.0, 1.0e30],
          operation <- [
            {:incr, key(), 1, {:expires, expiry}},
            {:cas, key(), :missing, 1, {:expires, expiry}},
          ],
          do: operation

    assert Client.route(nil, context) == {:error, :invalid_request}

    for operation <-
          [{:unsupported, key()}, {:get, :bad_key}, {:get, {nil, {}, 1}}] ++
            malformed_expiries do
      assert batch(%{one: operation}, context) ==
               %{one: {:error, :invalid_request}}
    end

    assert CounterBudgetHelper.remaining_us(context.batch) == 250_000
    assert :ets.lookup(:counter_client_test, node()) == []
  end

  test "malformed anchored expiries are refused before budget and cooldown admission", %{
    store: store,
  } do
    context = event(store)
    CounterBudgetHelper.batch(context.batch, 0)

    operations = %{
      incr: {:incr, key(), 1, {:expires, nil}},
      cas: {:cas, key(), :missing, 1, {:expires, "bad"}},
    }

    errors = %{incr: {:error, :invalid_request}, cas: {:error, :invalid_request}}
    assert batch(operations, context) == errors
    assert CounterBudgetHelper.remaining_us(context.batch) == 0

    CounterBudgetHelper.batch(context.batch, 5)
    cooldown = {node(), System.monotonic_time(:microsecond) + 10_000_000}
    :ets.insert(:counter_client_test, cooldown)
    assert batch(operations, context) == errors
    assert CounterBudgetHelper.remaining_us(context.batch) == 250_000
    assert :ets.lookup(:counter_client_test, node()) == [cooldown]
  end

  test "malformed anchored writes leave healthy siblings and integer expiries intact", %{
    store: store,
  } do
    CounterBudgetHelper.relax()
    context = event(store)
    expiry = System.monotonic_time(:millisecond) + 60_000
    incr_key = key({}, 2)
    cas_key = key({}, 3)

    assert batch(
             %{
               bad_incr: {:incr, key(), 1, {:expires, nil}},
               bad_cas: {:cas, key(), :missing, 1, {:expires, "bad"}},
               read: {:get, key()},
               incr: {:incr, incr_key, 2, {:expires, expiry}},
               cas: {:cas, cas_key, :missing, 3, {:expires, expiry}},
               expired: {:incr, key({}, 4), 1, {:expires, expiry - 120_000}},
             },
             context
           ) == %{
             bad_incr: {:error, :invalid_request},
             bad_cas: {:error, :invalid_request},
             read: :not_found,
             incr: {:ok, 2},
             cas: :ok,
             expired: {:error, :expired},
           }

    assert Store.get(key(), server: store) == :not_found
    assert Store.get(incr_key, server: store) == {:ok, 2}
    assert Store.get(cas_key, server: store) == {:ok, 3}
    assert CounterBudgetHelper.remaining_us(context.batch) == 250_000
    assert :ets.lookup(:counter_client_test, node()) == []
  end

  test "dispatch keeps each response at its operation's position around expired writes", %{
    store: store,
  } do
    CounterBudgetHelper.relax()
    context = event(store)
    live = System.monotonic_time(:millisecond) + 60_000
    elapsed = live - 120_000

    ops = [
      {:incr, key({}, 1), 1, {:expires, elapsed}},
      {:incr, key({}, 2), 2, {:expires, live}},
      {:cas, key({}, 3), :missing, 3, {:expires, elapsed}},
      {:get, key({}, 2)},
      {:incr, key({}, 5), 4, {:expires, elapsed}},
    ]

    assert Client.dispatch([{node(), ops}], context) ==
             [
               {node(),
                [
                  {:error, :expired},
                  {:ok, 2},
                  {:error, :expired},
                  {:ok, 2},
                  {:error, :expired},
                ]},
             ]

    assert Store.get(key({}, 1), server: store) == :not_found
    assert CounterBudgetHelper.remaining_us(context.batch) == 250_000

    # With every write expired nothing dispatches, and the reservation is refunded.
    expired = [
      {:incr, key({}, 6), 1, {:expires, elapsed}},
      {:incr, key({}, 7), 1, {:expires, elapsed}},
    ]

    assert Client.dispatch([{node(), expired}], context) ==
             [{node(), [{:error, :expired}, {:error, :expired}]}]

    assert Store.get(key({}, 6), server: store) == :not_found
    assert CounterBudgetHelper.remaining_us(context.batch) == 250_000
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
    # A malformed reply is charged its elapsed wait and never marks cooldown whatever
    # the call reserved, so a larger budget does not change what this checks; it keeps
    # the 2 ms reply from timing out under host load.
    CounterBudgetHelper.relax()

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

      context = event({Guardian.Test.Counters.ProbeStore, store})

      assert batch(%{a: {:get, key()}}, context) ==
               %{a: {:error, :invalid_response}}

      assert CounterBudgetHelper.remaining_us(context.batch) < 250_000
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
    CounterBudgetHelper.relax()
    context = event(store)
    atom_key = key({:group})

    assert batch_one({:incr, atom_key, 1, 5_000}, context) == {:ok, 1}
    assert Store.get(atom_key, server: store) == {:ok, 1}
  end

  test "local native operations preserve nil, tokens, colocation and definite errors", %{
    store: store,
  } do
    CounterBudgetHelper.relax()
    context = event(store)
    assert batch_one({:cas, key(), :missing, nil, 5_000}, context) == :ok
    assert {:ok, nil, token} = batch_one({:gets, key()}, context)
    assert batch_one({:cas, key(), token, 7, 5_000}, context) == :ok
    assert batch_one({:cas, key(), token, 8, 5_000}, context) == {:error, :conflict}
    assert batch_one({:incr, key(), 2, 5_000}, context) == {:ok, 9}

    assert batch(
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
    CounterBudgetHelper.relax([peer])

    for {server, members} <- [{store, [node()]}, {Store, [peer]}],
        value <- [{:error, :unavailable}, [{:error, :timeout}, {:error, :unavailable}]] do
      context = event(server, members: members)
      stored_key = key({System.unique_integer([:positive])})
      assert batch_one({:cas, stored_key, :missing, value, 5_000}, context) == :ok
      assert batch_one({:get, stored_key}, context) == {:ok, value}
      assert {:ok, ^value, _token} = batch_one({:gets, stored_key}, context)
      assert CounterBudgetHelper.remaining_us(context.batch) == 250_000
      assert :ets.tab2list(:counter_client_test) == []
    end
  end

  test "peer get/gets/CAS/incr carry native terms and reference tokens", %{peer_node: peer} do
    CounterBudgetHelper.relax([peer])
    context = event(Store, members: [peer])
    key = key({System.unique_integer([:positive])})
    value = %{nested: [nil, 1, 1.0, {"native", true}]}
    assert batch_one({:cas, key, :missing, value, 5_000}, context) == :ok
    assert {:ok, ^value, token} = batch_one({:gets, key}, context)
    assert {table, version} = token
    assert is_reference(table) and is_integer(version)
    assert batch_one({:cas, key, token, 3, 5_000}, context) == :ok
    assert batch_one({:incr, key, 2, 5_000}, context) == {:ok, 5}

    assert batch(%{one: {:get, key}, two: {:get, key}}, context) ==
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
      args = &Guardian.Test.Aggregation.args(name, arity, &1)
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
    {peer, booting} = Guardian.Test.Cluster.start_peer(nil)
    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    # The refusal and the cooldown it marks do not depend on the call budget; a larger
    # one only keeps a cold peer's first call from timing out under host load.
    :ok = :erpc.call(booting, Guardian.Test.Counters.Client, :preload, [])
    CounterBudgetHelper.relax([booting])
    context = event(Store, members: [booting])
    assert batch_one({:incr, key(), 1, 5_000}, context) == {:error, :unavailable}
    assert batch_one({:get, key()}, context) == {:error, :cooldown}
    :ok = :peer.stop(peer)
    lost = event(store, members: [booting])
    assert batch_one({:get, key()}, lost) in [{:error, :unavailable}, {:error, :cooldown}]
    assert Store.get(key(), server: store) == :not_found
  end

  test "local stall times out, queued mutation expires, cooldown recovers", %{store: store} do
    pause = Guardian.Test.Counters.StorePause.pause(store)
    started = System.monotonic_time(:millisecond)

    try do
      assert batch_one({:incr, key(), 1, 5_000}, event(store)) == {:error, :timeout}
      assert batch_one({:incr, key(), 1, 5_000}, event(store)) == {:error, :cooldown}
      # Rules out waits far beyond the 50 ms call budget, such as one bounded only by
      # the paused store, which never answers. Under host load it no longer catches a
      # wait of a few hundred ms; the results still assert the timeout and the
      # cooldown fast-fail.
      assert System.monotonic_time(:millisecond) - started < 1_000
    after
      Guardian.Test.Counters.StorePause.resume(pause)
    end

    assert Store.get(key(), server: store) == :not_found
    Process.sleep(1_010)
    assert batch_one({:incr, key(), 1, 5_000}, event(store)) == {:ok, 1}
  end

  test "short call and exhausted event budget do not mark an owner", %{store: store} do
    pause = Guardian.Test.Counters.StorePause.pause(store)

    try do
      assert batch_one({:get, key()}, event(store, timeout_ms: 15)) == {:error, :timeout}
      assert :ets.lookup(:counter_client_test, node()) == []
      batch = Client.new_batch()

      context =
        event(batch, store, event_timeout_ms: 5)

      assert batch_one({:get, key()}, context) == {:error, :budget_exhausted}
      assert CounterBudgetHelper.remaining_us(batch) == 250_000
      assert :ets.lookup(:counter_client_test, node()) == []
    after
      Guardian.Test.Counters.StorePause.resume(pause)
    end
  end

  test "large healthy local and peer batches never spend the failure budget", %{
    store: store,
    peer_node: peer,
  } do
    # A healthy call is refunded in full whatever it reserved, so a larger budget does
    # not change what this checks; it keeps a slow healthy call from timing out.
    CounterBudgetHelper.relax([peer])

    for {target, members} <- [{store, [node()]}, {Store, [peer]}] do
      batch = Client.new_batch()
      key = key({System.unique_integer([:positive])})

      for n <- 1..300 do
        context =
          event(batch, target, members: members)

        assert batch_one({:incr, key, 1, 30_000}, context) == {:ok, n}
      end

      assert CounterBudgetHelper.remaining_us(batch) == 250_000
    end
  end

  test "long batches stop failed waits across replacement workers for local and frozen peer", %{
    store: store,
    peer_node: peer,
  } do
    for {target, members, suspend_node} <- [{store, [node()], node()}, {Store, [peer], peer}] do
      pause = :erpc.call(suspend_node, Guardian.Test.Counters.StorePause, :pause, [target])
      batch = Client.new_batch()
      started = System.monotonic_time(:millisecond)

      try do
        outcomes =
          for _ <- 1..100 do
            # 15ms calls avoid cooldown to exercise the shared failed-wait cap itself.
            task =
              Task.async(fn ->
                context =
                  event(batch, target, members: members, timeout_ms: 15)

                batch_one({:get, key()}, context)
              end)

            Task.await(task)
          end

        assert Enum.all?(outcomes, &(&1 in [{:error, :timeout}, {:error, :budget_exhausted}]))
        # The 250 ms allowance fits about 17 failed 15 ms waits (25 leaves room for
        # deadlines truncated to whole milliseconds); without the shared cap all 100
        # would time out.
        assert Enum.count(outcomes, &(&1 == {:error, :timeout})) in 1..25
        assert CounterBudgetHelper.remaining_us(batch) < 10_000
        # Guards against a call outliving its 15 ms deadline: the paused store or
        # frozen peer never answers, so such a call would hang. The outcome count, not
        # this bound, proves the shared cap.
        assert System.monotonic_time(:millisecond) - started < 1_500
      after
        :erpc.call(suspend_node, Guardian.Test.Counters.StorePause, :resume, [pause])
      end
    end
  end

  test "caller death conservatively charges its reservation and terminates helpers", %{
    store: store,
  } do
    # Scaled budget (Guardian.Test.Counters.Budget): under load the production 50 ms call could
    # time out before the test sees its helpers and kills the caller. A 1 s unit with an
    # allowance of five units keeps the reservation decision and its retention the same.
    CounterBudgetHelper.scale()
    unit = CounterBudgetHelper.allowance_us(1)
    pause = Guardian.Test.Counters.StorePause.pause(store)
    batch = CounterBudgetHelper.batch(5)

    context =
      event(batch, store, members: [node()])

    caller = spawn(fn -> batch_one({:incr, key(), 1, 5_000}, context) end)

    try do
      Guardian.Test.Processes.await_queued_call(elem(pause, 0))
      helpers = counter_helpers()
      assert length(helpers) >= 2
      Process.exit(caller, :kill)
      Guardian.Test.Polling.eventually(fn -> Enum.all?(helpers, &(not Process.alive?(&1))) end)
      assert CounterBudgetHelper.remaining_us(batch) >= 4 * unit
      assert CounterBudgetHelper.remaining_us(batch) < 5 * unit
    after
      Guardian.Test.Counters.StorePause.resume(pause)
    end
  end

  test "deadline races leave neither helper processes nor reply messages" do
    store = start_supervised!({Task, fn -> delayed_store() end})

    for _ <- 1..80 do
      # Replies straddle the 10ms boundary, including already-delivered replies
      # racing the caller's timer. Neither outcome may leave messages behind.
      context = event({Guardian.Test.Counters.ProbeStore, store}, timeout_ms: 10)
      assert batch_one({:get, key()}, context) in [:not_found, {:error, :timeout}]
    end

    Guardian.Test.Polling.eventually(fn -> counter_helpers() == [] end)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "overlapping callers cannot reserve more than the shared failure allowance", %{
    store: store,
  } do
    pause = Guardian.Test.Counters.StorePause.pause(store)
    batch = Client.new_batch()

    try do
      outcomes =
        1..30
        |> Task.async_stream(
          fn _ ->
            context =
              event(batch, store, members: [node()])

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
      assert CounterBudgetHelper.remaining_us(batch) >= 0
    after
      Guardian.Test.Counters.StorePause.resume(pause)
    end

    assert Store.get(key(), server: store) == :not_found
  end

  test "frozen peer and distribution backpressure cannot outlive the failure budget" do
    {peer_controller, peer} = Guardian.Test.Cluster.start_peer(nil)
    {:ok, _} = :erpc.call(peer, Guardian.Test.Counters.Client, :start_store, [])
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
            event(batch, Store, members: [peer], timeout_ms: 15)

          batch_one({:cas, key, :missing, payload, 5_000}, context)
        end

      assert Enum.all?(outcomes, &(&1 in [{:error, :timeout}, {:error, :budget_exhausted}]))
      assert Enum.count(outcomes, &(&1 == {:error, :timeout})) in 1..25
      assert CounterBudgetHelper.remaining_us(batch) < 10_000
      # Guards against a call blocked in distribution backpressure outliving its 15 ms
      # deadline: the stopped peer never drains, so such a call would hang. The
      # timeout count, not this bound, proves the shared cap.
      assert System.monotonic_time(:millisecond) - started < 1_500
      Guardian.Test.Polling.eventually(fn -> counter_helpers() == [] end)
      assert {:messages, []} = Process.info(self(), :messages)
    after
      {_, 0} = System.cmd("/bin/kill", ["-CONT", os_pid])
      :peer.stop(peer_controller)
    end
  end

  test "cooldown expires without reads, departed members are pruned, absent routing fails fast",
       %{store: store} do
    {peer, member} = Guardian.Test.Cluster.start_peer(nil)
    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    future = System.monotonic_time(:microsecond) + 10_000_000
    :ets.insert(:counter_client_test, {member, future})
    :peer.stop(peer)
    Guardian.Test.Polling.eventually(fn -> :ets.lookup(:counter_client_test, member) == [] end)

    :ets.insert(:counter_client_test, {node(), System.monotonic_time(:microsecond) - 1})
    send(Process.whereis(:counter_client_test), :cleanup)
    Guardian.Test.Polling.eventually(fn -> :ets.tab2list(:counter_client_test) == [] end)

    # Scaled budget: with an allowance of five units, a call that waited instead of
    # failing fast could take a whole 1 s call budget, so a 500 ms bound still
    # separates the two under host load. The store is healthy, so a call dispatched
    # anyway would answer :not_found quickly; the result code is the main check.
    CounterBudgetHelper.scale()
    batch = CounterBudgetHelper.batch(5)

    context =
      event(batch, store, members: [node()])

    stop_supervised(Budget)
    started = System.monotonic_time(:millisecond)
    assert batch_one({:get, key()}, context) == {:error, :cooldown}
    assert System.monotonic_time(:millisecond) - started < 500
  end

  defp batch_one(operation, event) do
    batch(%{one: operation}, event).one
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

defmodule Guardian.Counters.ClientPeerTest do
  @moduledoc """
  Client across connected peers, and the local tests that find Transport's helper
  processes by scanning. `Guardian.Counters.ClientTest` has the rest.
  """
  # Not async: starts a connected peer node, which changes every test on this node, and
  # finds helper processes by scanning the whole VM.
  use ExUnit.Case, async: false
  @moduletag :cluster
  import Guardian.Counters.Client
  import Guardian.Test.Counters.Client, only: [batch_one: 2, key: 0, key: 1, named: 2]
  alias Guardian.Counters.Budget
  alias Guardian.Counters.Store
  alias Guardian.Counters.Transport
  alias Guardian.Test.Counters.Budget, as: CounterBudgetHelper

  setup_all do
    {_peer, peer_node} = Guardian.Test.Cluster.bare_peer()

    {:ok, _} = :erpc.call(peer_node, Guardian.Test.Counters.Client, :start_store, [])
    Guardian.Test.Counters.Client.await_ready(peer_node)
    %{peer_node: peer_node}
  end

  setup do
    store = start_supervised!({Store, name: nil})
    start_supervised!({Budget, name: :counter_client_peer_test})
    %{store: store}
  end

  defp event(store, opts) do
    event(new_batch(), store, opts)
  end

  defp event(batch, store, opts) do
    new_event(
      batch,
      Keyword.merge(
        [store: store, members: [node()], cooldown_table: :counter_client_peer_test],
        opts
      )
    )
  end

  defp owned_key(owner, members) do
    {identity, _group, _bucket} = key()
    n = Enum.find(1..10_000, &(Transport.owner({identity, {&1}}, members) == owner))
    key({n})
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

    # Buckets differ by owner and the probe echoes them, so an answer that lands on
    # another owner's operation fails.
    [local_ops, remote_ops] =
      for {owner, base} <- [{node(), 10}, {peer, 20}] do
        {identity, group, _} = owned_key(owner, members)
        for n <- 1..4, do: {:get, {identity, group, base + n}}
      end

    # Owners interleave, and a malformed operation sits among them.
    {before, rest} =
      remote_ops |> Enum.zip(local_ops) |> Enum.flat_map(&Tuple.to_list/1) |> Enum.split(3)

    ops = before ++ [{:get, :bad_key}] ++ rest

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
    assert %{one => first_ops, two => second_ops} == %{node() => local_ops, peer => remote_ops}
    send(first, :release)
    send(second, :release)

    assert Task.await(task) ==
             Enum.map(ops, fn
               {:get, {_, _, bucket}} -> {:ok, bucket}
               {:get, :bad_key} -> {:error, :invalid_request}
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
    limited = new_batch()
    expiry = System.monotonic_time(:millisecond) + 10

    task =
      Task.async(fn ->
        context =
          event(
            limited,
            {Guardian.Test.Counters.ProbeStore, Guardian.Test.Counters.PipelineProbe},
            members: members
          )

        named(
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

        named(
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
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "pending healthy owners use refunds, even with more than five owners or a spent budget", %{
    peer_node: peer,
  } do
    extra = for _ <- 1..4, do: Guardian.Test.Cluster.bare_peer()
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

      assert named(ops, context) == Map.new(members, &{&1, :not_found})
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

    # Input order is reversed, so only Client's sort starts the five earliest owners.
    ops = members |> Enum.sort(:desc) |> Enum.map(&{&1, {:get, owned_key(&1, members)}})
    batch = CounterBudgetHelper.batch(5)

    task =
      Task.async(fn ->
        context =
          event(batch, {Guardian.Test.Counters.ProbeStore, Guardian.Test.Counters.PipelineProbe},
            members: members
          )

        named(ops, context)
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
        named(
          %{local: {:incr, local_key, 1, 5_000}, remote: {:incr, remote_key, 1, 5_000}},
          context
        )

      assert results == %{local: {:ok, 1}, remote: {:error, :timeout}}
      assert CounterBudgetHelper.remaining_us(context.batch) in 200_000..225_000
      assert Store.get(local_key, now(), server: local) == {:ok, 1}
      assert [{^peer, _}] = :ets.lookup(:counter_client_peer_test, peer)
      assert :ets.lookup(:counter_client_peer_test, node()) == []

      assert named(
               %{remote: {:get, remote_key}},
               event(:counter_partial_store, members: members)
             ) == %{remote: {:error, :cooldown}}

      # A translated remote deadline may outlive the caller by transit time.
      Guardian.Test.Processes.await_queued_call(elem(pause, 0), node: peer)
      Process.sleep(55)
    after
      :erpc.call(peer, Guardian.Test.Counters.StorePause, :resume, [pause])
    end

    assert :erpc.call(peer, Store, :get, [remote_key, now(peer), [server: remote]]) == :not_found
    :erpc.call(peer, GenServer, :stop, [remote])
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "batch caller death terminates every owner helper and retains reservations", %{
    store: store,
  } do
    # Scaled budget (Guardian.Test.Counters.Budget): under load the production 50 ms call could
    # time out before the test sees its helpers and kills the caller. A 1 s unit with an
    # allowance of five units keeps the reservation decision and its retention the same.
    unit = CounterBudgetHelper.healthy_allowance_us(:scaled, 1)
    pause = Guardian.Test.Counters.StorePause.pause(store)
    {options, batch} = CounterBudgetHelper.healthy()

    caller =
      spawn(fn ->
        context = event(batch, store, options)
        named(%{a: {:incr, key(), 1, 5_000}}, context)
      end)

    try do
      Guardian.Test.Processes.await_queued_call(elem(pause, 0))
      helpers = counter_helpers()
      assert length(helpers) >= 2
      Process.exit(caller, :kill)
      Guardian.Test.Polling.eventually(fn -> Enum.all?(helpers, &(not Process.alive?(&1))) end)
      assert CounterBudgetHelper.remaining_us(batch) in (4 * unit)..(5 * unit - 1)
      # A dispatched call can survive its caller. Leave it queued past its own deadline.
      Process.sleep(div(unit, 1_000) + 5)
    after
      Guardian.Test.Counters.StorePause.resume(pause)
    end

    assert Store.get(key(), now(), server: store) == :not_found
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

    assert :erpc.call(peer, Store, :get, [remote_key, now(peer), []]) == :not_found
  end

  test "successful error-shaped values remain opaque through local and peer pipelines", %{
    store: store,
    peer_node: peer,
  } do
    CounterBudgetHelper.relax([peer])

    batch = CounterBudgetHelper.batch(5)

    for {server, members} <- [{store, [node()]}, {Store, [peer]}],
        value <- [{:error, :unavailable}, [{:error, :timeout}, {:error, :unavailable}]] do
      context = event(batch, server, members: members)
      stored_key = key({System.unique_integer([:positive])})
      assert batch_one({:add, stored_key, value, 5_000}, context) == :ok
      assert batch_one({:get, stored_key}, context) == {:ok, value}
      assert {:ok, ^value, _token} = batch_one({:gets, stored_key}, context)
      assert CounterBudgetHelper.remaining_us(batch) == CounterBudgetHelper.allowance_us(5)
      assert :ets.tab2list(:counter_client_peer_test) == []
    end
  end

  test "peer get/gets/add/CAS/incr carry native terms and integer tokens", %{peer_node: peer} do
    CounterBudgetHelper.relax([peer])
    context = event(CounterBudgetHelper.batch(5), Store, members: [peer])
    key = key({System.unique_integer([:positive])})
    value = %{nested: [nil, 1, 1.0, {"native", true}]}
    assert batch_one({:add, key, value, 5_000}, context) == :ok
    assert {:ok, ^value, token} = batch_one({:gets, key}, context)
    assert is_integer(token)
    assert batch_one({:cas, key, token, 3, 5_000}, context) == :ok
    assert batch_one({:incr, key, 2, 5_000}, context) == {:ok, 5}

    assert named(%{one: {:get, key}, two: {:get, key}}, context) ==
             %{one: {:ok, 5}, two: {:ok, 5}}

    assert :erpc.call(peer, Store, :get, [key, now(peer), []]) == {:ok, 5}
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

        assert :erpc.call(owner, Store, :add, [key, state, 5_000, now(owner), opts]) == :ok

        assert {:ok, restored, token} = :erpc.call(owner, Store, :gets, [key, now(owner), opts])
        assert :erlang.term_to_binary(restored) == encoded
        unchanged = :erpc.call(owner, Aggregation, :merge, [aggregation, restored, empty])
        assert :erlang.term_to_binary(unchanged) == encoded
        merged = :erpc.call(owner, Aggregation, :merge, [aggregation, restored, delta])
        expected = Aggregation.merge(aggregation, state, delta)
        assert :erlang.term_to_binary(merged) == :erlang.term_to_binary(expected)

        assert :erpc.call(owner, Store, :cas, [key, token, merged, 5_000, now(owner), opts]) ==
                 :ok

        assert {:ok, reread} = :erpc.call(owner, Store, :get, [key, now(owner), opts])
        assert :erlang.term_to_binary(reread) == :erlang.term_to_binary(expected)

        assert :erpc.call(owner, Aggregation, :finish, [aggregation, reread]) ===
                 Aggregation.finish(aggregation, expected)
      end
    end
  end

  test "booting and lost owners fail immediately without readiness or failover", %{store: store} do
    {peer, booting} = Guardian.Test.Cluster.bare_peer()
    # The refusal and the cooldown it marks do not depend on the call budget; a larger
    # one only keeps a cold peer's first call from timing out under host load.
    :ok = :erpc.call(booting, Guardian.Test.Counters.Client, :preload, [])
    CounterBudgetHelper.relax([booting])
    context = event(CounterBudgetHelper.batch(5), Store, members: [booting])
    assert batch_one({:incr, key(), 1, 5_000}, context) == {:error, :unavailable}
    assert batch_one({:get, key()}, context) == {:error, :cooldown}
    :ok = :peer.stop(peer)
    lost = event(context.batch, store, members: [booting])
    assert batch_one({:get, key()}, lost) in [{:error, :unavailable}, {:error, :cooldown}]
    assert Store.get(key(), now(), server: store) == :not_found
  end

  test "large healthy local and peer batches never spend the failure budget", %{
    store: store,
    peer_node: peer,
  } do
    # A healthy call is refunded in full whatever it reserved, so a larger budget does
    # not change what this checks; it keeps a slow healthy call from timing out.
    CounterBudgetHelper.relax([peer])

    for {target, members} <- [{store, [node()]}, {Store, [peer]}] do
      batch = CounterBudgetHelper.batch(5)
      key = key({System.unique_integer([:positive])})

      for n <- 1..300 do
        context =
          event(batch, target, members: members)

        assert batch_one({:incr, key, 1, 30_000}, context) == {:ok, n}
      end

      assert CounterBudgetHelper.remaining_us(batch) == CounterBudgetHelper.allowance_us(5)
    end
  end

  test "long batches stop failed waits across replacement workers for local and frozen peer", %{
    store: store,
    peer_node: peer,
  } do
    for {target, members, suspend_node} <- [{store, [node()], node()}, {Store, [peer], peer}] do
      pause = :erpc.call(suspend_node, Guardian.Test.Counters.StorePause, :pause, [target])
      batch = new_batch()
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
    unit = CounterBudgetHelper.healthy_allowance_us(:scaled, 1)
    pause = Guardian.Test.Counters.StorePause.pause(store)
    {options, batch} = CounterBudgetHelper.healthy()
    context = event(batch, store, options)
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

  test "deadline races leave no reply messages" do
    store = start_supervised!({Task, fn -> delayed_store() end})

    for _ <- 1..80 do
      # Replies straddle the 10ms boundary, including already-delivered replies
      # racing the caller's timer. Neither outcome may leave messages behind.
      context = event({Guardian.Test.Counters.ProbeStore, store}, timeout_ms: 10)
      assert batch_one({:get, key()}, context) in [:not_found, {:error, :timeout}]
    end

    assert {:messages, []} = Process.info(self(), :messages)
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

    batch = new_batch()
    key = key({System.unique_integer([:positive])})
    payload = :binary.copy("x", 8 * 1_024 * 1_024)
    {_, 0} = System.cmd("/bin/kill", ["-STOP", os_pid])
    started = System.monotonic_time(:millisecond)

    try do
      outcomes =
        for _ <- 1..60 do
          context =
            event(batch, Store, members: [peer], timeout_ms: 15)

          batch_one({:add, key, payload, 5_000}, context)
        end

      assert Enum.all?(outcomes, &(&1 in [{:error, :timeout}, {:error, :budget_exhausted}]))
      assert Enum.count(outcomes, &(&1 == {:error, :timeout})) in 1..25
      assert CounterBudgetHelper.remaining_us(batch) < 10_000
      # Guards against a call blocked in distribution backpressure outliving its 15 ms
      # deadline: the stopped peer never drains, so such a call would hang. The
      # timeout count, not this bound, proves the shared cap.
      assert System.monotonic_time(:millisecond) - started < 1_500
      assert {:messages, []} = Process.info(self(), :messages)
    after
      {_, 0} = System.cmd("/bin/kill", ["-CONT", os_pid])
      :peer.stop(peer_controller)
    end
  end

  test "cooldown expires without reads, departed members are pruned, absent routing fails fast",
       %{store: store} do
    {peer, member} = Guardian.Test.Cluster.bare_peer()
    future = System.monotonic_time(:microsecond) + 10_000_000
    :ets.insert(:counter_client_peer_test, {member, future})
    :peer.stop(peer)

    Guardian.Test.Polling.eventually(fn ->
      :ets.lookup(:counter_client_peer_test, member) == []
    end)

    :ets.insert(:counter_client_peer_test, {node(), System.monotonic_time(:microsecond) - 1})
    send(Process.whereis(:counter_client_peer_test), :cleanup)
    Guardian.Test.Polling.eventually(fn -> :ets.tab2list(:counter_client_peer_test) == [] end)

    # Scaled budget: with an allowance of five units, a call that waited instead of
    # failing fast could take a whole 1 s call budget, so a 500 ms bound still
    # separates the two under host load. The store is healthy, so a call dispatched
    # anyway would answer :not_found quickly; the result code is the main check.
    {options, batch} = CounterBudgetHelper.healthy()
    context = event(batch, store, options)
    stop_supervised(Budget)
    started = System.monotonic_time(:millisecond)
    assert batch_one({:get, key()}, context) == {:error, :cooldown}
    assert System.monotonic_time(:millisecond) - started < 500
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

  # Store operations take the current local monotonic milliseconds as data, read on
  # the store's own node: an instant never crosses nodes.
  defp now(node \\ node()) do
    :erpc.call(node, System, :monotonic_time, [:millisecond])
  end
end

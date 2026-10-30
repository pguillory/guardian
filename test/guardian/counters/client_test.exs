defmodule Guardian.Counters.ClientTest do
  @moduledoc """
  Client on this node's owners alone. `Guardian.Counters.ClientPeerTest` has the tests
  that need peers or scan for Transport's helper processes.
  """
  use ExUnit.Case, async: true
  import Guardian.Counters.Client
  import Guardian.Test.Counters.Client, only: [batch_one: 2, key: 0, key: 1, key: 2, named: 2]
  alias Guardian.Counters.Budget
  alias Guardian.Counters.Store
  alias Guardian.Counters.Transport
  alias Guardian.Test.Counters.Budget, as: CounterBudgetHelper

  # Long enough that a slow start never trims a reservation below the 50 ms call budget.
  @long_event [event_timeout_ms: 10_000]

  setup do
    store = start_supervised!({Store, name: nil})
    start_supervised!({Budget, name: :counter_client_test})
    %{store: store}
  end

  defp event(store, opts \\ []) do
    event(new_batch(), store, opts)
  end

  defp event(batch, store, opts) do
    new_event(
      batch,
      Keyword.merge(
        [store: store, members: [node()], cooldown_table: :counter_client_test],
        opts
      )
    )
  end

  defp route({identity, group, _bucket}) do
    {identity, group}
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

    assert batch([nil], context) == [{:error, :invalid_request}]

    for operation <-
          [{:unsupported, key()}, {:get, :bad_key}, {:get, {nil, {}, 1}}] ++
            malformed_expiries do
      assert named(%{one: operation}, context) ==
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
    assert named(operations, context) == errors
    assert CounterBudgetHelper.remaining_us(context.batch) == 0

    CounterBudgetHelper.batch(context.batch, 5)
    cooldown = {node(), System.monotonic_time(:microsecond) + 10_000_000}
    :ets.insert(:counter_client_test, cooldown)
    assert named(operations, context) == errors
    assert CounterBudgetHelper.remaining_us(context.batch) == 250_000
    assert :ets.lookup(:counter_client_test, node()) == [cooldown]
  end

  test "malformed anchored writes leave healthy siblings and integer expiries intact", %{
    store: store,
  } do
    context = event(store, CounterBudgetHelper.relaxed_options())
    expiry = System.monotonic_time(:millisecond) + 60_000
    incr_key = key({}, 2)
    cas_key = key({}, 3)

    assert named(
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

    assert Store.get(key(), now(), server: store) == :not_found
    assert Store.get(incr_key, now(), server: store) == {:ok, 2}
    assert Store.get(cas_key, now(), server: store) == {:ok, 3}
    assert CounterBudgetHelper.remaining_us(context.batch) == 250_000
    assert :ets.lookup(:counter_client_test, node()) == []
  end

  test "batch keeps each response at its operation's position around expired writes", %{
    store: store,
  } do
    context = event(store, CounterBudgetHelper.relaxed_options())
    live = System.monotonic_time(:millisecond) + 60_000
    elapsed = live - 120_000

    ops = [
      {:incr, key({}, 1), 1, {:expires, elapsed}},
      {:incr, key({}, 2), 2, {:expires, live}},
      {:cas, key({}, 3), :missing, 3, {:expires, elapsed}},
      {:get, key({}, 2)},
      {:incr, key({}, 5), 4, {:expires, elapsed}},
    ]

    assert batch(ops, context) ==
             [
               {:error, :expired},
               {:ok, 2},
               {:error, :expired},
               {:ok, 2},
               {:error, :expired},
             ]

    assert Store.get(key({}, 1), now(), server: store) == :not_found
    assert CounterBudgetHelper.remaining_us(context.batch) == 250_000

    # With every write expired nothing dispatches, and the reservation is refunded.
    expired = [
      {:incr, key({}, 6), 1, {:expires, elapsed}},
      {:incr, key({}, 7), 1, {:expires, elapsed}},
    ]

    assert batch(expired, context) == [{:error, :expired}, {:error, :expired}]

    assert Store.get(key({}, 6), now(), server: store) == :not_found
    assert CounterBudgetHelper.remaining_us(context.batch) == 250_000
    assert :ets.lookup(:counter_client_test, node()) == []
  end

  test "an owner's pipeline keeps input order above 32 operations" do
    parent = self()

    probe =
      start_supervised!(
        {Guardian.Test.Counters.ProbeStore,
         {:pipeline,
          fn ops ->
            send(parent, {:pipeline, ops})
            {:ok, Enum.map(ops, fn {:get, {_, _, bucket}} -> {:ok, bucket} end)}
          end}}
      )

    ops = for n <- 1..40, do: {:get, key({}, n)}

    context =
      event(
        {Guardian.Test.Counters.ProbeStore, probe},
        CounterBudgetHelper.relaxed_options()
      )

    assert batch(ops, context) == for(n <- 1..40, do: {:ok, n})
    assert_receive {:pipeline, ^ops}
  end

  test "the remote endpoint refuses scalar operations", %{store: store} do
    for operation <- [{:get, key()}, {:incr, key(), 1, 5_000}] do
      assert Transport.remote_operation(operation, store, 50) == {:error, :invalid_request}
    end

    assert Store.get(key(), now(), server: store) == :not_found
  end

  test "malformed pipeline replies are charged consistently and never escape as exceptions" do
    # A malformed reply is charged its elapsed wait and never marks cooldown whatever
    # the call reserved, so a larger budget does not change what this checks; it keeps
    # the 2 ms reply from timing out under host load.
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

      context =
        event({Guardian.Test.Counters.ProbeStore, store}, CounterBudgetHelper.relaxed_options())

      assert named(%{a: {:get, key()}}, context) ==
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
    context = event(store, CounterBudgetHelper.relaxed_options())
    atom_key = key({:group})

    assert batch_one({:incr, atom_key, 1, 5_000}, context) == {:ok, 1}
    assert Store.get(atom_key, now(), server: store) == {:ok, 1}
  end

  test "local native operations preserve nil, tokens, colocation and definite errors", %{
    store: store,
  } do
    context = event(store, CounterBudgetHelper.relaxed_options())
    assert batch_one({:cas, key(), :missing, nil, 5_000}, context) == :ok
    assert {:ok, nil, token} = batch_one({:gets, key()}, context)
    assert batch_one({:cas, key(), token, 7, 5_000}, context) == :ok
    assert batch_one({:cas, key(), token, 8, 5_000}, context) == {:error, :conflict}
    assert batch_one({:incr, key(), 2, 5_000}, context) == {:ok, 9}

    assert named(
             %{missing: {:get, key({}, 2)}, present: {:get, key()}},
             context
           ) == %{missing: :not_found, present: {:ok, 9}}

    assert batch_one({:cas, key({}, 3), :missing, "text", 5_000}, context) == :ok
    assert batch_one({:incr, key({}, 3), 1, 5_000}, context) == {:error, :not_integer}
    assert :ets.lookup(:counter_client_test, node()) == []
  end

  test "local stall times out, queued mutation expires, cooldown recovers", %{store: store} do
    pause = Guardian.Test.Counters.StorePause.pause(store)
    started = System.monotonic_time(:millisecond)

    try do
      assert batch_one({:incr, key(), 1, 5_000}, event(store, @long_event)) == {:error, :timeout}
      assert batch_one({:incr, key(), 1, 5_000}, event(store, @long_event)) == {:error, :cooldown}
      # Rules out waits far beyond the 50 ms call budget, such as one bounded only by
      # the paused store, which never answers. Under host load it no longer catches a
      # wait of a few hundred ms; the results still assert the timeout and the
      # cooldown fast-fail.
      assert System.monotonic_time(:millisecond) - started < 1_000
    after
      Guardian.Test.Counters.StorePause.resume(pause)
    end

    assert Store.get(key(), now(), server: store) == :not_found
    Process.sleep(1_010)
    recovered = event(store, CounterBudgetHelper.relaxed_options())
    assert batch_one({:incr, key(), 1, 5_000}, recovered) == {:ok, 1}
  end

  test "short call and exhausted event budget do not mark an owner", %{store: store} do
    pause = Guardian.Test.Counters.StorePause.pause(store)

    try do
      assert batch_one({:get, key()}, event(store, [timeout_ms: 15] ++ @long_event)) ==
               {:error, :timeout}

      assert :ets.lookup(:counter_client_test, node()) == []
      batch = new_batch()

      context =
        event(batch, store, event_timeout_ms: 5)

      assert batch_one({:get, key()}, context) == {:error, :budget_exhausted}
      assert CounterBudgetHelper.remaining_us(batch) == 250_000
      assert :ets.lookup(:counter_client_test, node()) == []
    after
      Guardian.Test.Counters.StorePause.resume(pause)
    end
  end

  test "overlapping callers cannot reserve more than the shared failure allowance", %{
    store: store,
  } do
    pause = Guardian.Test.Counters.StorePause.pause(store)
    batch = new_batch()

    try do
      outcomes =
        1..30
        |> Task.async_stream(
          fn _ ->
            batch_one({:incr, key(), 1, 5_000}, event(batch, store, @long_event))
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

    assert Store.get(key(), now(), server: store) == :not_found
  end

  # Store operations take the current local monotonic milliseconds as data.
  defp now do
    System.monotonic_time(:millisecond)
  end
end

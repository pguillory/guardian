defmodule Guardian.Counters.ClientTest do
  @moduledoc """
  Client on this node's owners alone. `Guardian.Counters.ClientPeerTest` has the tests
  that need peers.
  """
  use ExUnit.Case, async: true
  import Guardian.Counters.Client
  import Guardian.Test.Counters.Client, only: [batch_one: 2, key: 0, key: 1, key: 2, named: 2]
  alias Guardian.Counters.Store
  alias Guardian.Counters.Transport
  alias Guardian.Test.Counters.ProbeStore

  setup do
    store = start_supervised!({Store, name: nil})
    %{store: store}
  end

  defp event(store, opts \\ []) do
    new_event(Keyword.merge([store: store, members: [node()]], opts))
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
            {:add, key(), 1, {:expires, expiry}},
            {:cas, key(), 1, 1, {:expires, expiry}},
          ],
          do: operation

    assert batch([nil], context) == [{:error, :invalid_request}]

    for operation <-
          [{:unsupported, key()}, {:get, :bad_key}, {:get, {nil, {}, 1}}] ++
            malformed_expiries do
      assert named(%{one: operation}, context) ==
               %{one: {:error, :invalid_request}}
    end
  end

  test "malformed anchored writes leave healthy siblings and integer expiries intact", %{
    store: store,
  } do
    context = event(store)
    expiry = System.monotonic_time(:millisecond) + 60_000
    incr_key = key({}, 2)
    add_key = key({}, 3)

    assert named(
             %{
               bad_incr: {:incr, key(), 1, {:expires, nil}},
               bad_add: {:add, key(), 1, {:expires, "bad"}},
               read: {:get, key()},
               incr: {:incr, incr_key, 2, {:expires, expiry}},
               add: {:add, add_key, 3, {:expires, expiry}},
               expired: {:incr, key({}, 4), 1, {:expires, expiry - 120_000}},
             },
             context
           ) == %{
             bad_incr: {:error, :invalid_request},
             bad_add: {:error, :invalid_request},
             read: :not_found,
             incr: {:ok, 2},
             add: :ok,
             expired: {:error, :expired},
           }

    assert batch_one({:get, key()}, context) == :not_found
    assert batch_one({:get, incr_key}, context) == {:ok, 2}
    assert batch_one({:get, add_key}, context) == {:ok, 3}
  end

  test "batch keeps each response at its operation's position around expired writes", %{
    store: store,
  } do
    context = event(store)
    live = System.monotonic_time(:millisecond) + 60_000
    elapsed = live - 120_000

    ops = [
      {:incr, key({}, 1), 1, {:expires, elapsed}},
      {:incr, key({}, 2), 2, {:expires, live}},
      {:add, key({}, 3), 3, {:expires, elapsed}},
      {:get, key({}, 2)},
      {:cas, key({}, 2), 1, 4, {:expires, elapsed}},
      {:incr, key({}, 5), 4, {:expires, elapsed}},
    ]

    assert batch(ops, context) ==
             [
               {:error, :expired},
               {:ok, 2},
               {:error, :expired},
               {:ok, 2},
               {:error, :expired},
               {:error, :expired},
             ]

    assert batch_one({:get, key({}, 1)}, context) == :not_found

    # With every write expired nothing dispatches.
    expired = [
      {:incr, key({}, 6), 1, {:expires, elapsed}},
      {:incr, key({}, 7), 1, {:expires, elapsed}},
    ]

    assert batch(expired, context) == [{:error, :expired}, {:error, :expired}]

    assert batch_one({:get, key({}, 6)}, context) == :not_found
  end

  test "an owner's pipeline keeps input order above 32 operations", %{store: store} do
    context = event(store)

    assert batch(for(n <- 1..40, do: {:add, key({}, n), n, 5_000}), context) ==
             List.duplicate(:ok, 40)

    assert batch(for(n <- 1..40, do: {:get, key({}, n)}), context) ==
             for(n <- 1..40, do: {:ok, n})
  end

  test "the remote endpoint refuses scalar operations", %{store: store} do
    for operation <- [{:get, key()}, {:incr, key(), 1, 5_000}] do
      assert Transport.remote_operation(operation, store, 50) == {:error, :invalid_request}
    end

    assert Store.get(key(), now(), server: store) == :not_found
  end

  test "malformed pipeline replies never escape as exceptions" do
    responses = [
      {:ok, []},
      {:ok, [:not_found | :improper]},
      {:error, "private"},
      {:ok, [{:error, "private"}]},
    ]

    for {response, index} <- Enum.with_index(responses) do
      probe =
        start_supervised!(
          {ProbeStore, {:pipeline, fn _operations -> response end}},
          id: {:malformed, index}
        )

      context = event({ProbeStore, probe})

      assert named(%{a: {:get, key()}}, context) ==
               %{a: {:error, :invalid_response}}
    end
  end

  test "a store that doesn't answer gives a timeout" do
    probe =
      start_supervised!({ProbeStore, {:pipeline, fn _operations -> Process.sleep(:infinity) end}})

    context = event({ProbeStore, probe}, timeout_ms: 10)
    assert batch_one({:get, key()}, context) == {:error, :timeout}
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
    assert batch_one({:get, atom_key}, context) == {:ok, 1}
  end

  test "local native operations preserve nil, tokens, colocation and definite errors", %{
    store: store,
  } do
    context = event(store)
    assert batch_one({:add, key(), nil, 5_000}, context) == :ok
    assert {:ok, nil, token} = batch_one({:gets, key()}, context)
    assert batch_one({:cas, key(), token, 7, 5_000}, context) == :ok
    assert batch_one({:cas, key(), token, 8, 5_000}, context) == {:error, :exists}
    assert batch_one({:incr, key(), 2, 5_000}, context) == {:ok, 9}

    assert named(
             %{missing: {:get, key({}, 2)}, present: {:get, key()}},
             context
           ) == %{missing: :not_found, present: {:ok, 9}}

    assert batch_one({:add, key({}, 3), "text", 5_000}, context) == :ok
    assert batch_one({:incr, key({}, 3), 1, 5_000}, context) == {:error, :not_integer}
  end

  # Store operations take the current local monotonic milliseconds as data.
  defp now do
    System.monotonic_time(:millisecond)
  end
end

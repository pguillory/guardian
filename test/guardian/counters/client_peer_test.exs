defmodule Guardian.Counters.ClientPeerTest do
  @moduledoc """
  Client across connected peers. `Guardian.Counters.ClientTest` has the rest.
  """
  # Not async: starts a connected peer node, which changes every test on this node.
  use ExUnit.Case, async: false
  @moduletag :cluster
  import Guardian.Counters.Client
  import Guardian.Test.Counters.Client, only: [batch_one: 2, key: 0, key: 1, named: 2]
  alias Guardian.Counters.Store
  alias Guardian.Counters.Transport

  setup_all do
    {_peer, peer_node} = Guardian.Test.Cluster.bare_peer()

    {:ok, _} = :erpc.call(peer_node, Guardian.Test.Counters.Client, :start_store, [])
    Guardian.Test.Counters.Client.await_ready(peer_node)
    %{peer_node: peer_node}
  end

  setup do
    store = start_supervised!({Store, name: nil})
    %{store: store}
  end

  defp event(store, opts) do
    new_event(Keyword.merge([store: store, members: [node()]], opts))
  end

  defp owned_key(owner, members) do
    {identity, _group, _bucket} = key()
    n = Enum.find(1..10_000, &(Transport.owner({identity, {&1}}, members) == owner))
    key({n})
  end

  test "a batch across owners answers each operation in place", %{peer_node: peer} do
    members = [node(), peer]
    local_key = owned_key(node(), members)
    remote_key = owned_key(peer, members)

    context = event(Store, members: members)
    :ok = :erpc.call(peer, Store, :add, [remote_key, "remote", 5_000, now(peer), []])
    :ok = Store.add(local_key, "local", 5_000, now(), [])

    assert batch(
             [{:get, remote_key}, {:get, local_key}, {:get, :bad_key}, {:get, remote_key}],
             context
           ) == [{:ok, "remote"}, {:ok, "local"}, {:error, :invalid_request}, {:ok, "remote"}]
  end

  test "the remote endpoint preserves batch replies and refuses bad durations", %{
    peer_node: peer,
  } do
    remote_key = key({"remote-endpoint"})

    assert :erpc.call(peer, Transport, :remote_operation, [
             {:batch, [{:get, remote_key}]},
             Store,
             50,
           ]) ==
             {:ok, [:not_found]}

    for duration <- [0, -1, 1.0, nil] do
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
    for {server, members} <- [{store, [node()]}, {Store, [peer]}],
        value <- [{:error, :unavailable}, [{:error, :timeout}, {:error, :unavailable}]] do
      context = event(server, members: members)
      stored_key = key({System.unique_integer([:positive])})
      assert batch_one({:add, stored_key, value, 5_000}, context) == :ok
      assert batch_one({:get, stored_key}, context) == {:ok, value}
      assert {:ok, ^value, _token} = batch_one({:gets, stored_key}, context)
    end
  end

  test "peer get/gets/add/CAS/incr carry native terms and integer tokens", %{peer_node: peer} do
    context = event(Store, members: [peer])
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
    # Keeps a cold peer's first call from timing out under host load.
    :ok = :erpc.call(booting, Guardian.Test.Counters.Client, :preload, [])
    context = event(Store, members: [booting])
    assert batch_one({:incr, key(), 1, 5_000}, context) == {:error, :unavailable}
    :ok = :peer.stop(peer)
    lost = event(store, members: [booting])
    assert batch_one({:get, key()}, lost) == {:error, :unavailable}
    assert Store.get(key(), now(), server: store) == :not_found
  end

  test "many calls on local and peer owners all answer", %{
    store: store,
    peer_node: peer,
  } do
    for {target, members} <- [{store, [node()]}, {Store, [peer]}] do
      key = key({System.unique_integer([:positive])})

      for n <- 1..300 do
        context = event(target, members: members)
        assert batch_one({:incr, key, 1, 30_000}, context) == {:ok, n}
      end
    end
  end

  # Store operations take the current local monotonic milliseconds as data, read on
  # the store's own node: an instant never crosses nodes.
  defp now(node \\ node()) do
    :erpc.call(node, System, :monotonic_time, [:millisecond])
  end
end

defmodule Guardian.Rules.CounterRoundsTest do
  @moduledoc "CounterRuntime's round loop and level results, with scripted owner dispatch."
  use ExUnit.Case, async: true
  alias Guardian.Aggregation
  alias Guardian.Counters.{Context, KeyMachines, Machine}
  alias Guardian.Rules.{CounterDefinition, CounterRuntime, Event}

  @sum Aggregation.fetch!("sum")
  @min Aggregation.fetch!("min")
  @max Aggregation.fetch!("max")

  defp context do
    Context.new(nil, members: [node()])
  end

  defp key(name, bucket \\ 1) do
    {{"events", name, "hash"}, {}, bucket}
  end

  defp expiry do
    System.monotonic_time(:millisecond) + 5_000
  end

  # A dispatch function answering each operation with `respond.(op)`, reporting
  # every round's batches to the test process.
  defp scripted(respond) do
    parent = self()

    fn batches, _context ->
      send(parent, {:round, batches})
      Enum.map(batches, fn {owner, ops} -> {owner, Enum.map(ops, respond)} end)
    end
  end

  defp run(machines, dispatch) do
    machines
    |> CounterRuntime.run_state_machines(context(), dispatch)
    |> Enum.map(fn machine ->
      assert Machine.done?(machine)
      machine.result
    end)
  end

  defp round_ops do
    assert_receive {:round, batches}
    Enum.flat_map(batches, &elem(&1, 1))
  end

  defp definition(operator, identity \\ {"events", "hits", "hash"}) do
    %CounterDefinition{
      identity: identity,
      operator: operator,
      window_ms: 3_000,
      bucket_ms: 1_000,
      group_arity: 0,
    }
  end

  defp event do
    %{Event.arrival() | counters: context()}
  end

  test "rounds batch every pending machine and return results in input order" do
    dispatch =
      scripted(fn
        {:get, {{_, "a", _}, _, _}} -> {:ok, nil}
        {:get, {{_, "b", _}, _, _}} -> :not_found
        {:incr, {{_, "c", _}, _, _}, 1, _} -> {:ok, 4}
        {:gets, {{_, "d", _}, _, _}} -> {:ok, 5, :token}
        {:cas, {{_, "d", _}, _, _}, :token, 7, _} -> :ok
      end)

    machines = [
      KeyMachines.read(key("a")),
      KeyMachines.read(key("b")),
      KeyMachines.incr(key("c"), 1, expiry()),
      KeyMachines.merge(@sum, key("d"), 2, expiry()),
    ]

    assert run(machines, dispatch) == [{:ok, nil}, :not_found, {:ok, 4}, {:ok, 7}]
    assert length(round_ops()) == 4
    assert [{:cas, {{_, "d", _}, _, _}, :token, 7, _}] = round_ops()
    refute_receive {:round, _}
  end

  test "interleaved owners and routing errors get their own responses, across rounds" do
    members = [node(), :peer@host]
    context = Context.new(nil, members: members)
    owner = fn key -> elem(Guardian.Counters.Client.route({:get, key}, context), 1) end
    keys = for n <- 1..40, do: key("m#{n}", n)
    [a1, a2] = keys |> Enum.filter(&(owner.(&1) == node())) |> Enum.take(2)
    [b1, b2] = keys |> Enum.filter(&(owner.(&1) == :peer@host)) |> Enum.take(2)
    parent = self()

    dispatch = fn batches, _context ->
      send(parent, {:round, batches})

      Enum.map(batches, fn {owner, ops} ->
        {owner,
         Enum.map(ops, fn
           {:get, key} -> {:ok, {owner, key}}
           {:gets, _} -> {:ok, 1, :token}
           {:cas, _, :token, _, _} -> :ok
         end)}
      end)
    end

    machines = [
      KeyMachines.read(b1),
      KeyMachines.read(a1),
      KeyMachines.read(:malformed),
      KeyMachines.merge(@sum, b2, 2, expiry()),
      KeyMachines.read(a2),
    ]

    assert machines
           |> CounterRuntime.run_state_machines(context, dispatch)
           |> Enum.map(& &1.result) ==
             [
               {:ok, {:peer@host, b1}},
               {:ok, {node(), a1}},
               {:error, :invalid_request},
               {:ok, 3},
               {:ok, {node(), a2}},
             ]

    assert_receive {:round, first}
    assert Enum.map(first, &elem(&1, 0)) == Enum.sort(members)
    assert_receive {:round, [{:peer@host, [{:cas, ^b2, :token, 3, _}]}]}
    refute_receive {:round, _}
  end

  test "no dispatch for no machines, finished machines or only routing errors" do
    dispatch = scripted(fn _ -> flunk("dispatched") end)
    assert run([], dispatch) == []
    assert CounterRuntime.run_counters([], event(), dispatch) == []

    assert run([KeyMachines.read(:malformed), KeyMachines.read({:also, :malformed})], dispatch) ==
             [{:error, :invalid_request}, {:error, :invalid_request}]

    refute_receive {:round, _}
  end

  test "operations in one owner's pipeline keep input order above 32 operations" do
    keys = for n <- 1..40, do: key("k#{n}", n)
    dispatch = scripted(fn {:get, _} -> :not_found end)

    assert run(Enum.map(keys, &KeyMachines.read/1), dispatch) == List.duplicate(:not_found, 40)
    assert_receive {:round, [{owner, ops}]}
    assert owner == node()
    assert ops == Enum.map(keys, &{:get, &1})
  end

  test "only definite conflicts retry, with three attempts, and callback exceptions are isolated" do
    parent = self()

    for failure <- [:conflict, :timeout] do
      dispatch =
        scripted(fn op ->
          send(parent, elem(op, 0))

          case op do
            {:gets, _} -> :not_found
            {:cas, _, _, _, _} -> {:error, failure}
          end
        end)

      assert run([KeyMachines.merge(@sum, key("k"), 1, expiry())], dispatch) ==
               [{:error, failure}]

      for _ <- 1..if(failure == :conflict, do: 3, else: 1) do
        assert_receive :gets
        assert_receive :cas
      end

      refute_receive :gets
    end

    broken = Machine.new({:get, key("bad")}, nil, fn _, _, _ -> raise "private" end)

    assert run([broken, KeyMachines.read(key("good"))], scripted(fn _ -> {:ok, 8} end)) ==
             [{:error, :invalid_state}, {:ok, 8}]
  end

  test "strict equality preserves numeric type changes and unchanged states skip CAS" do
    parent = self()

    dispatch =
      scripted(fn
        {:gets, _} ->
          {:ok, 1, :token}

        {:cas, _, _, value, _} ->
          send(parent, {:write, value})
          :ok
      end)

    assert run(
             [
               KeyMachines.merge(@min, key("k"), 1.0, expiry()),
               KeyMachines.merge(@max, key("k"), 0, expiry()),
             ],
             dispatch
           ) == [{:ok, 1.0}, {:ok, 1}]

    assert_receive {:write, value}
    assert value === 1.0
    refute_receive {:write, _}
  end

  test "bucket errors default quietly; expansion and round failures are reported per op" do
    sum = definition({"sum", 1})
    ok = scripted(fn {:get, _} -> {:ok, 2} end)

    # Four buckets of 2, while an unknown operator fails only its own op.
    assert [{:ok, 8}, {:error, expansion}, {:ok, 8}] =
             CounterRuntime.run_counters(
               [
                 {:lookup, sum, {}},
                 {:lookup, definition({"no_such_aggregate", 1}), {}},
                 {:lookup, sum, {}},
               ],
               event(),
               ok
             )

    assert is_binary(expansion)

    # A malformed routing key defaults only its own op.
    assert CounterRuntime.run_counters(
             [
               {:lookup, sum, {}},
               {:lookup, definition({"sum", 1}, {"events", "hits", :bad}), {}},
               {:lookup, sum, {}},
             ],
             event(),
             ok
           ) == [{:ok, 8}, {:ok, Aggregation.default(@sum)}, {:ok, 8}]

    # A timed-out bucket and a malformed routing key default without an error.
    timeout = scripted(fn {:get, _} -> {:error, :timeout} end)
    missing = Aggregation.default(@sum)

    assert CounterRuntime.run_counters(
             [
               {:lookup, sum, {}},
               {:lookup, definition({"sum", 1}, {"events", "hits", :bad}), {}},
             ],
             event(),
             timeout
           ) == [{:ok, missing}, {:ok, missing}]

    # A reply missing a response fails the level open; the expansion failure keeps
    # its own kind.
    short = fn batches, _ -> Enum.map(batches, fn {owner, [_ | ops]} -> {owner, ops} end) end

    assert [{:error, round}, {:error, ^expansion}] =
             CounterRuntime.run_counters(
               [{:lookup, sum, {}}, {:lookup, definition({"no_such_aggregate", 1}), {}}],
               event(),
               short
             )

    assert is_binary(round)
  end
end

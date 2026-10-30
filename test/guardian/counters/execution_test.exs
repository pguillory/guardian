defmodule Guardian.Counters.ExecutionTest do
  @moduledoc """
  Execution's round loop and level results, its buckets, expiries, CAS attempts and
  budgets, through the real Client against a private store or a scripted
  `Guardian.Test.Counters.ProbeStore`.
  """
  # Every owner is this node, and budgets are per event, so nothing here is node-wide.
  use ExUnit.Case, async: true
  import Guardian.Counters.Execution
  alias Guardian.Aggregation
  alias Guardian.Counters.Arrival
  alias Guardian.Counters.Definition
  alias Guardian.Counters.KeyMachines
  alias Guardian.Counters.LookupOperation
  alias Guardian.Counters.Machine
  alias Guardian.Counters.Store
  alias Guardian.Counters.TrackOperation
  alias Guardian.Test.Counters.Budget, as: CounterBudgetHelper
  alias Guardian.Test.Counters.ProbeStore

  @sum Aggregation.fetch!("sum")
  @min Aggregation.fetch!("min")
  @max Aggregation.fetch!("max")

  # No test here depends on the production 50 ms call or 100 ms event budget: the
  # allowance test depends on the 250 ms batch allowance. Larger budgets keep healthy calls, including a cold first
  # call, from timing out under host load and setting a cooldown that fails later calls
  # open. A response of {:error, :timeout} from a call that reserved at least 25 ms, or
  # any {:error, :unavailable}, does set one.
  setup do
    Guardian.Test.Counters.private_store(:counters_execution_test)
  end

  defp tracked(operator, window_ms) do
    Definition.new({"events", "tracked", inspect(operator)}, operator, window_ms, 0)
  end

  defp event(
         store,
         batch \\ Guardian.Counters.Client.new_batch(),
         arrival \\ Arrival.now(),
         opts \\ []
       ) do
    context =
      Guardian.Counters.Client.new_event(
        batch,
        Guardian.Test.Counters.event_options(
          store,
          :counters_execution_test,
          Keyword.merge(CounterBudgetHelper.relaxed_options(), opts)
        )
      )

    %{arrival: arrival, context: context}
  end

  defp context(store) do
    event(store).context
  end

  # One statement through the level runner, unwrapped to its counter value.
  defp track(definition, group, values, event) do
    [{:ok, value}] =
      run_counters(
        [%TrackOperation{definition: definition, group: group, values: values}],
        event.arrival,
        event.context
      )

    value
  end

  defp lookup(definition, group, event) do
    [{:ok, value}] =
      run_counters([lookup_op(definition, group)], event.arrival, event.context)

    value
  end

  defp lookup_op(definition, group \\ {}) do
    %LookupOperation{definition: definition, group: group}
  end

  defp key(name, bucket \\ 1) do
    {{"events", name, "hash"}, {}, bucket}
  end

  defp expiry do
    System.monotonic_time(:millisecond) + 5_000
  end

  # A store answering each operation with `respond.(op)`, reporting every round's
  # operations to the test process. `respond` runs in the probe: a failure there
  # reaches the test as the probe's `{:error, :unavailable}`, not as a failed assertion.
  defp scripted(respond) do
    parent = self()

    start_supervised!(
      {ProbeStore,
       {:pipeline,
        fn ops ->
          send(parent, {:round, ops})
          {:ok, Enum.map(ops, respond)}
        end}},
      id: make_ref()
    )
  end

  defp run(machines, store) do
    machines
    |> run_state_machines(context(store))
    |> Enum.map(fn machine ->
      assert Machine.done?(machine)
      machine.result
    end)
  end

  defp round_ops do
    assert_receive {:round, ops}
    ops
  end

  defp definition(operator, identity \\ {"events", "hits", "hash"}) do
    Definition.new(identity, operator, 3_000, 0)
  end

  test "rounds batch every pending machine and return results in input order" do
    store =
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

    assert run(machines, store) == [{:ok, nil}, :not_found, {:ok, 4}, {:ok, 7}]
    assert length(round_ops()) == 4
    assert [{:cas, {{_, "d", _}, _, _}, :token, 7, _}] = round_ops()
    refute_receive {:round, _}
  end

  test "no store call or budget for no machines or only routing errors" do
    context = context(scripted(fn _ -> :not_found end))

    assert run_state_machines([], context) == []
    assert run_counters([], Arrival.now(), context) == []

    assert [KeyMachines.read(:malformed), KeyMachines.read({:also, :malformed})]
           |> run_state_machines(context)
           |> Enum.map(& &1.result) == [{:error, :invalid_request}, {:error, :invalid_request}]

    refute_receive {:round, _}
    assert CounterBudgetHelper.remaining_us(context.batch) == 250_000
  end

  test "callback exceptions are isolated" do
    broken = Machine.new({:get, key("bad")}, nil, fn _, _, _ -> raise "private" end)

    assert run([broken, KeyMachines.read(key("good"))], scripted(fn _ -> {:ok, 8} end)) ==
             [{:error, :invalid_state}, {:ok, 8}]
  end

  test "strict equality preserves numeric type changes and unchanged states skip CAS" do
    parent = self()

    store =
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
             store
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
             run_counters(
               [
                 lookup_op(sum),
                 lookup_op(definition({"no_such_aggregate", 1})),
                 lookup_op(sum),
               ],
               Arrival.now(),
               context(ok)
             )

    assert is_binary(expansion)

    # A malformed routing key defaults only its own op.
    assert run_counters(
             [
               lookup_op(sum),
               lookup_op(definition({"sum", 1}, {"events", "hits", :bad})),
               lookup_op(sum),
             ],
             Arrival.now(),
             context(ok)
           ) == [{:ok, 8}, {:ok, Aggregation.default(@sum)}, {:ok, 8}]

    # A timed-out bucket and a malformed routing key default without an error. The short
    # call keeps the timeout from setting a cooldown.
    timeout = scripted(fn {:get, _} -> {:error, :timeout} end)
    missing = Aggregation.default(@sum)

    timeout_event =
      event(timeout, Guardian.Counters.Client.new_batch(), Arrival.now(), timeout_ms: 20)

    assert run_counters(
             [
               lookup_op(sum),
               lookup_op(definition({"sum", 1}, {"events", "hits", :bad})),
             ],
             timeout_event.arrival,
             timeout_event.context
           ) == [{:ok, missing}, {:ok, missing}]

    # A raised round (membership routing cannot hash) fails the level open; the
    # expansion failure keeps its own kind.
    raising = event(ok, Guardian.Counters.Client.new_batch(), Arrival.now(), members: [])

    assert [{:error, round}, {:error, ^expansion}] =
             run_counters(
               [lookup_op(sum), lookup_op(definition({"no_such_aggregate", 1}))],
               raising.arrival,
               raising.context
             )

    assert is_binary(round)
    assert round != expansion
  end

  test "boundary reads include the complete oldest bucket and exclude older buckets", %{
    store: store,
  } do
    definition = tracked({"count", 0}, 1_000)
    arrival = %{Arrival.now() | unix_ms: 10_000}
    current = Integer.floor_div(arrival.unix_ms, definition.bucket_ms)
    first = Integer.floor_div(arrival.unix_ms - definition.window_ms, definition.bucket_ms)

    for bucket <- (first - 1)..current do
      assert {:ok, 1} =
               Store.incr({definition.identity, {}, bucket}, 1, 10_000, now(), server: store)
    end

    assert lookup(
             definition,
             {},
             event(store, Guardian.Counters.Client.new_batch(), arrival)
           ) == current - first + 1

    assert track(
             definition,
             {},
             [],
             event(store, Guardian.Counters.Client.new_batch(), arrival)
           ) == current - first + 2
  end

  test "whole-batch arrivals that expire before execution never create a bucket", %{
    store: store,
  } do
    definition = tracked({"count", 0}, 1_000)
    arrival = %{Arrival.now() | monotonic_ms: System.monotonic_time(:millisecond) - 2_000}

    assert track(
             definition,
             {},
             [],
             event(store, Guardian.Counters.Client.new_batch(), arrival)
           ) == 0

    assert {:ok, %{keys: 0}} = Store.stats(server: store)
  end

  test "unchanged generic states and zero count deltas do not create or refresh keys", %{
    store: store,
  } do
    for operator <- [{"count", 1}, {"sum", 1}, {"min", 1}, {"count_distinct", 1}] do
      definition = tracked(operator, 3_600_000)

      assert track(definition, {}, [nil], event(store)) ==
               Aggregation.default(Aggregation.fetch!(elem(definition.operator, 0)))
    end

    assert {:ok, %{keys: 0}} = Store.stats(server: store)
    definition = tracked({"max", 1}, 3_600_000)
    event = event(store)
    assert track(definition, {}, [10], event) == 10
    bucket = Integer.floor_div(event.arrival.unix_ms, definition.bucket_ms)
    key = {definition.identity, {}, bucket}
    assert {:ok, 10, token} = Store.gets(key, now(), server: store)
    assert track(definition, {}, [1], event(store)) == 10
    assert {:ok, 10, ^token} = Store.gets(key, now(), server: store)
  end

  test "bucket merging remains chronological and retains the newest numeric tie type", %{
    store: store,
  } do
    for operator <- ["min", "max"] do
      definition = tracked({operator, 1}, 3_600_000)
      event = event(store)
      current = Integer.floor_div(event.arrival.unix_ms, definition.bucket_ms)

      assert :ok =
               Store.add({definition.identity, {}, current - 1}, 1.0, 5_000, now(), server: store)

      assert track(definition, {}, [1], event) === 1

      assert lookup(definition, {}, event) === 1
      assert track(definition, {}, [1.0], event(store)) === 1.0
    end
  end

  test "lost races have three total attempts and uncertain writes are never retried" do
    parent = self()

    # The timeout comes last because it sets a cooldown. A retry would then answer
    # {:error, :cooldown} without reaching the probe, which the result below would catch.
    for failure <- [:not_stored, :timeout] do
      store =
        scripted(fn
          {:gets, _} ->
            :not_found

          {:add, _, 5, _ttl} ->
            send(parent, :attempt)
            {:error, failure}
        end)

      assert run([KeyMachines.merge(@sum, key("k"), 5, expiry())], store) == [{:error, failure}]
      assert_receive :attempt

      if failure == :not_stored do
        assert_receive :attempt
        assert_receive :attempt
      end

      refute_receive :attempt, 10
    end
  end

  test "add, cas and cas of a vanished row share the three attempts" do
    answers =
      start_supervised!({Agent, fn -> [:not_found, {:ok, 3, :token}, {:ok, 3, :token}] end})

    store =
      scripted(fn
        {:gets, _} -> Agent.get_and_update(answers, fn [next | rest] -> {next, rest} end)
        {:add, _, _, _} -> {:error, :not_stored}
        {:cas, _, :token, _, _} -> :not_found
      end)

    assert run([KeyMachines.merge(@sum, key("k"), 5, expiry())], store) ==
             [{:error, :not_found}]

    assert [
             [{:gets, _}],
             [{:add, _, _, _}],
             [{:gets, _}],
             [{:cas, _, _, _, _}],
             [{:gets, _}],
             [{:cas, _, _, _, _}],
           ] = for(_ <- 1..6, do: round_ops())

    refute_received {:round, _}
  end

  test "a cas that keeps finding another token finishes with that error" do
    store =
      scripted(fn
        {:gets, _} -> {:ok, 3, :token}
        {:cas, _, :token, _, _} -> {:error, :exists}
      end)

    assert run([KeyMachines.merge(@sum, key("k"), 5, expiry())], store) == [{:error, :exists}]
  end

  test "a cas that keeps finding no row defaults the statement, not just its bucket" do
    definition = tracked({"sum", 1}, 3_600_000)

    store =
      start_supervised!(
        {ProbeStore,
         fn
           {:get, _} -> {:ok, 40}
           {:gets, _} -> {:ok, 1, 7}
           {:cas, _, _, _, _} -> :not_found
         end}
      )

    assert track(definition, {}, [5], event(store)) ==
             Aggregation.default(Aggregation.fetch!("sum"))
  end

  test "a lost cas refetches and merges the new current state" do
    definition = tracked({"sum", 1}, 3_600_000)
    attempt = start_supervised!({Agent, fn -> 0 end})
    parent = self()

    store =
      start_supervised!(
        {ProbeStore,
         fn
           {:get, _} ->
             :not_found

           {:gets, _} ->
             {:ok, if(Agent.get(attempt, & &1) == 0, do: 3, else: 5), 1}

           {:cas, _, _, merged, _} ->
             send(parent, {:merged, merged})

             if Agent.get_and_update(attempt, &{&1, &1 + 1}) == 0,
               do: {:error, :exists},
               else: :ok
         end}
      )

    assert track(definition, {}, [5], event(store)) == 10
    assert_receive {:merged, 8}
    assert_receive {:merged, 10}
    assert Agent.get(attempt, & &1) == 2
  end

  test "a failed bucket defaults the whole result even when its parallel writer succeeds" do
    definition = tracked({"count", 0}, 3_600_000)
    parent = self()

    store =
      start_supervised!(
        {ProbeStore,
         fn operation ->
           send(parent, operation)

           case operation do
             {:get, _} -> {:error, :evicted}
             {:incr, _, _, _} -> {:ok, 99}
           end
         end}
      )

    assert track(definition, {}, [], event(store)) == 0
    assert_receive {:get, _}
    assert_receive {:incr, _, _, _}
  end

  test "TTL uses fixed expiry and decreases with elapsed private monotonic time" do
    definition = tracked({"count", 0}, 3_600_000)
    parent = self()

    store =
      start_supervised!(
        {ProbeStore,
         fn
           {:get, _} ->
             :not_found

           {:incr, _, _, ttl} ->
             send(parent, {:ttl, ttl})
             {:ok, 1}
         end}
      )

    # Mid-bucket: expiry is bucket_end+W, not arrival+B+W.
    arrival = %{Arrival.now() | unix_ms: 7_800_000}

    assert track(
             definition,
             {},
             [],
             event(store, Guardian.Counters.Client.new_batch(), arrival)
           ) == 1

    assert_receive {:ttl, first}
    assert first in 4_199_000..4_200_000
    older = %{arrival | monotonic_ms: arrival.monotonic_ms - 1_000}

    assert track(
             definition,
             {},
             [],
             event(store, Guardian.Counters.Client.new_batch(), older)
           ) == 1

    assert_receive {:ttl, second}
    assert (first - second) in 1_000..2_000
  end

  test "generic TRACK merges the state it successfully wrote without reading it back" do
    definition = tracked({"sum", 1}, 3_600_000)
    parent = self()

    store =
      start_supervised!(
        {ProbeStore,
         fn operation ->
           send(parent, operation)

           case operation do
             {:get, _} -> {:ok, 2}
             {:gets, _} -> {:ok, 3, :token}
             {:cas, _, :token, 8, _} -> :ok
           end
         end}
      )

    event = event(store)

    expected_prior =
      Integer.floor_div(event.arrival.unix_ms, definition.bucket_ms) -
        Integer.floor_div(event.arrival.unix_ms - definition.window_ms, definition.bucket_ms)

    assert track(definition, {}, [5], event) == 8 + 2 * expected_prior
    for _ <- 1..expected_prior, do: assert_receive({:get, _})
    assert_receive {:gets, _}
    assert_receive {:cas, _, :token, 8, _}
    refute_receive {:gets, _}, 10
    refute_receive {:get, _}, 10
  end

  test "a slow gets cannot dispatch an add after fixed expiry" do
    definition = tracked({"sum", 1}, 1_000)
    parent = self()

    store =
      start_supervised!(
        {ProbeStore,
         fn operation ->
           send(parent, operation)

           case operation do
             {:get, _} ->
               :not_found

             {:gets, _} ->
               Process.sleep(25)
               :not_found

             {:add, _, _, _} ->
               :ok
           end
         end}
      )

    # At Unix 0 the fixed expiry is 1334 ms later; leave 15 ms now.
    arrival = %{
      Arrival.now()
      | unix_ms: 0,
        monotonic_ms: System.monotonic_time(:millisecond) - 1_319,
    }

    assert track(
             definition,
             {},
             [5],
             event(store, Guardian.Counters.Client.new_batch(), arrival)
           ) == nil

    assert_receive {:gets, _}
    refute_receive {:add, _, _, _}, 10
  end

  test "healthy large batches refund the budget and include every event", %{store: store} do
    # A healthy call is refunded in full whatever it reserved, so the relaxed budget
    # does not change what this checks.
    definition = tracked({"count", 0}, 3_600_000)
    batch = Guardian.Counters.Client.new_batch()

    for n <- 1..300,
        do: assert(track(definition, {}, [], event(store, batch)) == n)

    assert CounterBudgetHelper.remaining_us(batch) == 250_000
  end

  test "concurrent native increments never omit the event's own mutation", %{store: store} do
    definition = tracked({"count", 0}, 3_600_000)

    values =
      1..20
      |> Task.async_stream(fn _ -> track(definition, {}, [], event(store)) end,
        max_concurrency: 4
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.sort(values) == Enum.to_list(1..20)
    assert lookup(definition, {}, event(store)) == 20
  end

  test "concurrent generic CAS updates include their event or explicitly default on conflict",
       %{
         store: store,
       } do
    # A nil final lookup under production budgets was consistent with one call timing
    # out at 50 ms and putting this node in cooldown, so the lookup failed open.
    definition = tracked({"sum", 1}, 3_600_000)

    values =
      1..30
      |> Task.async_stream(fn _ -> track(definition, {}, [1], event(store)) end,
        max_concurrency: 3
      )
      |> Enum.map(fn {:ok, value} -> value end)
      |> Enum.reject(&is_nil/1)

    assert length(values) > 0
    assert Enum.sort(values) == Enum.to_list(1..length(values))
    assert lookup(definition, {}, event(store)) == length(values)
  end

  # Store operations take the current local monotonic milliseconds as data.
  defp now do
    System.monotonic_time(:millisecond)
  end
end

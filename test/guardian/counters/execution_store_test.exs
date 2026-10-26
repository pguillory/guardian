defmodule Guardian.Counters.ExecutionStoreTest do
  @moduledoc """
  Execution's buckets, expiries, CAS attempts and budgets against a store. Its round
  loop and level results with scripted dispatch are in `Guardian.Counters.ExecutionTest`.
  """
  # Uses the node-wide budget seam (`Guardian.Test.Counters.Budget`).
  use ExUnit.Case, async: false
  alias Guardian.Aggregation
  alias Guardian.Counters.{Arrival, Definition, Execution, Store}
  alias Guardian.Test.Counters.Budget, as: CounterBudgetHelper
  alias Guardian.Test.Counters.ProbeStore

  # No test here depends on the production 50 ms call or 100 ms event budget: the
  # timeout tests pass shorter explicit timeouts, which stay capped, and the
  # allowance test depends on the 250 ms batch allowance. Larger budgets keep healthy
  # calls, including a cold first call, from timing out under host load and setting
  # a cooldown that fails later calls open.
  setup do
    Guardian.Test.Counters.relaxed_store(:counters_execution_test)
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
        Guardian.Test.Counters.event_options(store, :counters_execution_test, opts)
      )

    %{arrival: arrival, context: context}
  end

  # One statement through the level runner, unwrapped to its counter value.
  defp track(definition, group, values, event) do
    [{:ok, value}] =
      Execution.run_counters(
        [{:track, definition, group, values}],
        event.arrival,
        event.context
      )

    value
  end

  defp lookup(definition, group, event) do
    [{:ok, value}] =
      Execution.run_counters([{:lookup, definition, group}], event.arrival, event.context)

    value
  end

  test "boundary reads include the complete oldest bucket and exclude older buckets", %{
    store: store,
  } do
    definition = tracked({"count", 0}, 1_000)
    arrival = %{Arrival.now() | unix_ms: 10_000}
    current = Integer.floor_div(arrival.unix_ms, definition.bucket_ms)
    first = Integer.floor_div(arrival.unix_ms - definition.window_ms, definition.bucket_ms)

    for bucket <- (first - 1)..current do
      assert {:ok, 1} = Store.incr({definition.identity, {}, bucket}, 1, 10_000, server: store)
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
    assert {:ok, 10, token} = Store.gets(key, server: store)
    assert track(definition, {}, [1], event(store)) == 10
    assert {:ok, 10, ^token} = Store.gets(key, server: store)
  end

  test "bucket merging remains chronological and retains the newest numeric tie type", %{
    store: store,
  } do
    for operator <- ["min", "max"] do
      definition = tracked({operator, 1}, 3_600_000)
      event = event(store)
      current = Integer.floor_div(event.arrival.unix_ms, definition.bucket_ms)

      assert :ok =
               Store.cas({definition.identity, {}, current - 1}, :missing, 1.0, 5_000,
                 server: store
               )

      assert track(definition, {}, [1], event) === 1

      assert lookup(definition, {}, event) === 1
      assert track(definition, {}, [1.0], event(store)) === 1.0
    end
  end

  test "CAS conflicts have three total attempts and uncertain writes are never retried" do
    definition = tracked({"sum", 1}, 3_600_000)
    parent = self()

    for failure <- [:conflict, :timeout] do
      store =
        start_supervised!(
          {ProbeStore,
           fn operation ->
             case operation do
               {:get, _} ->
                 :not_found

               {:gets, _} ->
                 :not_found

               {:cas, _, :missing, 5, _ttl} ->
                 send(parent, :attempt)
                 {:error, failure}
             end
           end}
        )

      # Below the 25 ms suspicion threshold, so cooldown cannot mask a retry.
      event =
        event(store, Guardian.Counters.Client.new_batch(), Arrival.now(), timeout_ms: 20)

      assert track(definition, {}, [5], event) == nil
      assert_receive :attempt

      if failure == :conflict do
        assert_receive :attempt
        assert_receive :attempt
      end

      refute_receive :attempt, 10
      stop_supervised!(ProbeStore)
      :ets.delete_all_objects(:counters_execution_test)
    end
  end

  test "a conflict retry refetches and merges the new current state" do
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
             {:ok, if(Agent.get(attempt, & &1) == 0, do: 3, else: 5), make_ref()}

           {:cas, _, _, merged, _} ->
             send(parent, {:merged, merged})

             if Agent.get_and_update(attempt, &{&1, &1 + 1}) == 0,
               do: {:error, :conflict},
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

  test "a slow gets cannot dispatch a CAS after fixed expiry" do
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

             {:cas, _, _, _, _} ->
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
    refute_receive {:cas, _, _, _, _}, 10
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
end

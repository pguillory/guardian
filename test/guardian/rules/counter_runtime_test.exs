defmodule Guardian.Rules.CounterRuntimeTest do
  use ExUnit.Case, async: false
  import Guardian.RulesTestHelper
  alias Guardian.Aggregation
  alias Guardian.Counters.Store
  alias Guardian.Rules.{CounterRuntime, DependencyGraph, Event, Runtime}

  setup do
    store = start_supervised!({Store, name: nil})
    start_supervised!({Guardian.Counters.Budget, name: :rules_counter_runtime_test})
    %{store: store}
  end

  defp event(
         store,
         batch \\ Guardian.Counters.Client.new_batch(),
         arrival \\ Event.arrival(),
         opts \\ []
       ) do
    Event.start(
      arrival,
      batch,
      Keyword.merge(
        [
          store: test_backend(store),
          members: [node()],
          cooldown_table: :rules_counter_runtime_test,
        ],
        opts
      )
    )
  end

  defp plans(files) do
    preparation = Guardian.Rules.RuleSet.prepare(files)
    assert preparation.errors == []
    Map.new(preparation.tables, fn {table, {:ok, plan}} -> {table, plan} end)
  end

  defp test_backend(store) when is_atom(store) do
    store
  end

  defp test_backend(store) do
    case Process.info(store, :dictionary) do
      {:dictionary, dictionary} ->
        if Keyword.has_key?(dictionary, :counter_store_descriptor),
          do: store,
          else: {Guardian.CounterStoreProbe, store}
    end
  end

  defp plan(source) do
    table = unique_table("counter_execution")
    plans(%{"#{table}/r.gsql" => source}) |> Map.fetch!(table)
  end

  defp run(plan, row, event) do
    Runtime.run(row, DependencyGraph.levels(plan.steps), event)
  end

  defp definition(plan) do
    plan.steps
    |> Enum.find(&(&1.kind == :track))
    |> Guardian.Rules.CounterDefinition.from_track()
  end

  test "LOOKUP barrier, SET dependencies, deduplication and the 50th event", %{store: store} do
    table = unique_table("counter_barrier")

    source = """
    TRACK hits = count() BY group_key LAST '1h';
    SET blocked = hits >= 50;
    UNSET secret;
    LOOKUP before = hits BY group_key;
    SET group_key = lower(ip)
    """

    plan =
      plans(%{
        "#{table}/a.gsql" => source,
        "#{table}/copy.gsql" => "TRACK hits = count() BY group_key LAST '1h'",
      })[table]

    batch = Guardian.Counters.Client.new_batch()

    for n <- 1..50 do
      row = run(plan, %{"ip" => "A", "secret" => "private"}, event(store, batch))
      assert row["hits"] == n
      assert row["before"] == n - 1
      assert row["blocked"] == n >= 50
      refute Map.has_key?(row, "secret")
    end

    assert :atomics.get(batch, 1) == 250_000
  end

  test "cross-table lookups preserve exact ordered typed groups, including null", %{store: store} do
    tracked = unique_table("counter_target")
    read = unique_table("counter_reader")

    plans =
      plans(%{
        "#{tracked}/r.gsql" => "TRACK hits = count() BY a, b LAST '1h'",
        "#{read}/r.gsql" => "LOOKUP prior = hits FROM #{tracked} BY x, y",
      })

    for value <- [1, 1.0, "1", nil, [1], %{"x" => 1}] do
      assert run(plans[tracked], %{"a" => value, "b" => "b"}, event(store))["hits"] == 1
      assert run(plans[read], %{"x" => value, "y" => "b"}, event(store))["prior"] == 1
      assert run(plans[read], %{"x" => "b", "y" => value}, event(store))["prior"] == 0
    end
  end

  test "initial counter levels index case-insensitive and absent inputs once", %{store: store} do
    grouped = plan("TRACK hits = count() BY ip LAST '1h'")
    assert run(grouped, %{"IP" => "a"}, event(store))["hits"] == 1
    assert run(grouped, %{"ip" => "a"}, event(store))["hits"] == 2
    assert run(grouped, %{}, event(store))["hits"] == 1
    assert run(grouped, %{"IP" => nil}, event(store))["hits"] == 2

    conditional = plan("TRACK hits = count() WHERE enabled LAST '1h';
      LOOKUP prior = hits WHERE enabled")

    assert run(conditional, %{"hits" => 99, "prior" => 98}, event(store)) ==
             %{"hits" => 99, "prior" => 98}

    assert Map.take(run(conditional, %{"ENABLED" => true}, event(store)), ~w(hits prior)) ==
             %{"hits" => 1, "prior" => 0}

    aggregates = plan("TRACK present = count(v) LAST '1h'; TRACK total = sum(v) LAST '1h'")

    assert Map.take(run(aggregates, %{"V" => 3}, event(store)), ~w(present total)) ==
             %{"present" => 1, "total" => 3}

    assert Map.take(run(aggregates, %{}, event(store)), ~w(present total)) ==
             %{"present" => 1, "total" => 3}
  end

  test "all operators merge windows and use their own missing results", %{store: store} do
    source = """
    TRACK n = count() LAST '1h'; TRACK present = count(v) LAST '1h';
    TRACK distinct_n = count_distinct(v) LAST '1h'; TRACK total = sum(v) LAST '1h';
    TRACK smallest = min(v) LAST '1h'; TRACK largest = max(v) LAST '1h';
    TRACK mean = avg(v) LAST '1h'; LOOKUP prior_total = total
    """

    plan = plan(source)
    rows = for value <- [nil, 2, 4, 2], do: run(plan, %{"v" => value}, event(store))
    assert hd(rows)["total"] == nil
    assert hd(rows)["mean"] == nil

    assert List.last(rows)
           |> Map.take(~w(n present distinct_n total smallest largest mean prior_total)) ==
             %{
               "n" => 4,
               "present" => 3,
               "distinct_n" => 2,
               "total" => 8,
               "smallest" => 2,
               "largest" => 4,
               "mean" => 8 / 3,
               "prior_total" => 6,
             }

    for {name, _arity} = operator <- Aggregation.names_and_arities() do
      defn = %{
        definition(plan)
        | operator: operator,
          aggregation: Aggregation.fetch!(name),
          identity: {plan.table, "missing", inspect(operator)},
      }

      assert CounterRuntime.lookup(defn, {}, event(store)) ==
               CounterRuntime.missing(defn.aggregation)
    end
  end

  test "every registered aggregate tracks through buckets with the query semantics", %{
    store: store,
  } do
    plan =
      plan("""
      TRACK any = arbitrary(v) LAST '1h'; TRACK top = max_n(v, 2) LAST '1h';
      TRACK low_names = min_n_by(name, v, 2) LAST '1h'; TRACK best = max_by(name, v) LAST '1h';
      TRACK every = all(ok) LAST '1h'; TRACK oks = count_if(ok) LAST '1h';
      TRACK spread = var_pop(v) LAST '1h'; LOOKUP prior_top = top
      """)

    fields = ~w(any top low_names best every oks spread prior_top)

    assert Map.take(run(plan, %{"v" => 3, "name" => "c", "ok" => true}, event(store)), fields) ==
             %{
               "any" => 3,
               "top" => [3],
               "low_names" => ["c"],
               "best" => "c",
               "every" => true,
               "oks" => 1,
               "spread" => 0.0,
               "prior_top" => nil,
             }

    run(plan, %{"v" => 1, "name" => "a", "ok" => true}, event(store))

    assert Map.take(run(plan, %{"v" => 5, "name" => "e", "ok" => false}, event(store)), fields) ==
             %{
               "any" => 3,
               "top" => [5, 3],
               "low_names" => ["a", "c"],
               "best" => "e",
               "every" => false,
               "oks" => 2,
               "spread" => 8 / 3,
               "prior_top" => [3, 1],
             }
  end

  test "arbitrary keeps a real null rather than treating it as no rows", %{store: store} do
    plan = plan("TRACK any = arbitrary(v) LAST '1h'; LOOKUP prior = any")

    assert Map.take(run(plan, %{}, event(store)), ~w(any prior)) == %{
             "any" => nil,
             "prior" => nil,
           }

    assert Map.take(run(plan, %{"v" => 1}, event(store)), ~w(any prior)) == %{
             "any" => nil,
             "prior" => nil,
           }

    definition = definition(plan)
    current = Integer.floor_div(event(store).arrival_ms, definition.bucket_ms)
    assert {:ok, nil} = Store.get({definition.identity, {}, current}, server: store)
  end

  test "top-N buckets that disagree on n fail open without affecting a sibling", %{store: store} do
    plan = plan("TRACK top = max_n(v, k) LAST '1h'; TRACK hits = count() LAST '1h'")
    definition = definition(plan)
    assert run(plan, %{"v" => 1, "k" => 2}, event(store))["top"] == [1]

    # The current bucket holds n = 2, so merging n = 3 into it fails that bucket.
    assert Map.take(run(plan, %{"v" => 2, "k" => 3}, event(store)), ~w(top hits)) ==
             %{"top" => nil, "hits" => 2}

    # An older bucket with another n fails the combination across buckets.
    context = event(store)
    current = Integer.floor_div(context.arrival_ms, definition.bucket_ms)
    older = {definition.identity, {}, current - 1}
    assert :ok = Store.cas(older, :missing, {[9], 1}, 5_000, server: store)

    assert Map.take(run(plan, %{"v" => 3, "k" => 2}, context), ~w(top hits)) ==
             %{"top" => nil, "hits" => 3}
  end

  test "WHERE false/null preserves fields; errors overwrite spoofed values and still UNSET", %{
    store: store,
  } do
    plan =
      plan("""
      TRACK hits = count() WHERE enabled LAST '1h';
      LOOKUP prior = hits WHERE enabled;
      SET decision = hits = 0;
      UNSET secret
      """)

    for enabled <- [false, nil] do
      row =
        run(
          plan,
          %{"hits" => 99, "prior" => 98, "enabled" => enabled, "secret" => "private"},
          event(store)
        )

      assert row["hits"] == 99
      assert row["prior"] == 98
      refute Map.has_key?(row, "secret")
    end

    assert {:ok, %{keys: 0}} = Store.stats(server: store)
    down = event(:rules_counter_absent)

    row =
      run(plan, %{"hits" => 99, "prior" => 98, "enabled" => true, "secret" => "private"}, down)

    assert row == %{"hits" => 0, "prior" => 0, "enabled" => true, "decision" => true}
  end

  test "counter scalar exceptions fail open while SET exceptions still fail closed", %{
    store: store,
  } do
    counter = plan("TRACK total = sum(test_raise(v)) LAST '1h'; UNSET secret")
    scalar = plan("SET bad = test_raise(v); UNSET secret")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert run(
                 counter,
                 %{"v" => "PRIVATE", "secret" => "PRIVATE", "total" => 99},
                 event(store)
               ) == %{"v" => "PRIVATE", "total" => nil}

        assert_raise Runtime.Failure, fn -> run(scalar, %{"v" => "PRIVATE"}, event(store)) end
      end)

    refute log =~ "PRIVATE"
  end

  test "boundary reads include the complete oldest bucket and exclude older buckets", %{
    store: store,
  } do
    definition = definition(plan("TRACK hits = count() LAST '1s'"))
    arrival = %{Event.arrival() | arrival_ms: 10_000}
    current = Integer.floor_div(arrival.arrival_ms, definition.bucket_ms)
    first = Integer.floor_div(arrival.arrival_ms - definition.window_ms, definition.bucket_ms)

    for bucket <- (first - 1)..current do
      assert {:ok, 1} = Store.incr({definition.identity, {}, bucket}, 1, 10_000, server: store)
    end

    assert CounterRuntime.lookup(
             definition,
             {},
             event(store, Guardian.Counters.Client.new_batch(), arrival)
           ) == current - first + 1

    assert CounterRuntime.track(
             definition,
             {},
             [],
             event(store, Guardian.Counters.Client.new_batch(), arrival)
           ) == current - first + 2
  end

  test "whole-batch arrivals that expire before execution never create a bucket", %{store: store} do
    definition = definition(plan("TRACK hits = count() LAST '1s'"))
    arrival = %{Event.arrival() | monotonic_ms: System.monotonic_time(:millisecond) - 2_000}

    assert CounterRuntime.track(
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
    for source <- [
          "TRACK hits = count(v) LAST '1h'",
          "TRACK hits = sum(v) LAST '1h'",
          "TRACK hits = min(v) LAST '1h'",
          "TRACK hits = count_distinct(v) LAST '1h'",
        ] do
      definition = definition(plan(source))

      assert CounterRuntime.track(definition, {}, [nil], event(store)) ==
               CounterRuntime.missing(definition.aggregation)
    end

    assert {:ok, %{keys: 0}} = Store.stats(server: store)
    definition = definition(plan("TRACK hits = max(v) LAST '1h'"))
    context = event(store)
    assert CounterRuntime.track(definition, {}, [10], context) == 10
    bucket = Integer.floor_div(context.arrival_ms, definition.bucket_ms)
    key = {definition.identity, {}, bucket}
    assert {:ok, 10, token} = Store.gets(key, server: store)
    assert CounterRuntime.track(definition, {}, [1], event(store)) == 10
    assert {:ok, 10, ^token} = Store.gets(key, server: store)
  end

  test "definition edits reset counters while moving identical source keeps state", %{
    store: store,
  } do
    table = unique_table("counter_identity")
    original = plans(%{"#{table}/a.gsql" => "TRACK hits = count() LAST '1h'"})[table]
    moved = plans(%{"#{table}/b.gsql" => "-- moved\nTRACK hits = count() LAST '1h'"})[table]
    edited = plans(%{"#{table}/a.gsql" => "TRACK hits = count() LAST '2h'"})[table]
    assert run(original, %{}, event(store))["hits"] == 1
    assert run(moved, %{}, event(store))["hits"] == 2
    assert run(edited, %{}, event(store))["hits"] == 1
  end

  defmodule ProbeStore do
    use GenServer

    def start_link(handler) do
      GenServer.start_link(__MODULE__, handler)
    end

    def init(handler) do
      {:ok, handler}
    end

    def handle_call(
          {:operation, _deadline, {:batch, operations}},
          _from,
          {:pipeline, handler} = state
        ) do
      {:reply, handler.(operations), state}
    end

    def handle_call({:operation, _deadline, {:batch, operations}}, _from, handler) do
      {:reply, {:ok, Enum.map(operations, handler)}, handler}
    end
  end

  test "each dependency level batches every counter and bucket into the longest machine's rounds" do
    parent = self()

    store =
      start_supervised!(
        {ProbeStore,
         {:pipeline,
          fn operations ->
            send(parent, {:pipeline_ops, operations})

            {:ok,
             Enum.map(operations, fn
               {:get, _} -> :not_found
               {:gets, _} -> :not_found
               {:incr, _, _, _} -> {:ok, 1}
               {:cas, _, _, _, _} -> :ok
             end)}
          end}}
      )

    plan =
      plan("""
      TRACK c = count() BY group_key LAST '1h';
      TRACK total = sum(v) LAST '1h';
      TRACK next_value = sum(c) LAST '1h';
      SET decision = next_value > 0;
      LOOKUP prior = c BY group_key;
      SET group_key = normalized;
      SET normalized = lower(ip);
      UNSET secret
      """)

    levels = DependencyGraph.levels(plan.steps)

    assert Enum.map(levels, fn level -> Enum.map(level, & &1.field) end) ==
             [
               ["normalized"],
               ["group_key"],
               ["prior"],
               ["c", "total"],
               ["next_value"],
               ["decision"],
               ["secret"],
             ]

    row = run(plan, %{"ip" => "A", "v" => 5, "secret" => "private"}, event(store))

    assert Map.take(row, ~w(prior c total next_value decision)) ==
             %{"prior" => 0, "c" => 1, "total" => 5, "next_value" => 1, "decision" => true}

    refute Map.has_key?(row, "secret")

    rounds =
      for _ <- 1..5 do
        assert_receive {:pipeline_ops, operations}
        operations
      end

    assert Enum.map(rounds, &length/1) == [4, 8, 1, 4, 1]
    assert Enum.all?(hd(rounds), &match?({:get, _}, &1))
    assert Enum.count(Enum.at(rounds, 1), &match?({:incr, _, _, _}, &1)) == 1
    assert Enum.count(Enum.at(rounds, 1), &match?({:gets, _}, &1)) == 1
    refute_receive {:pipeline_ops, _}, 10
  end

  test "a scalar failure prevents all dispatch for its level" do
    parent = self()

    store =
      start_supervised!(
        {ProbeStore,
         {:pipeline,
          fn operations ->
            send(parent, {:unexpected, operations})
            {:ok, []}
          end}}
      )

    plan = plan("TRACK hits = count() LAST '1h'; SET bad = test_raise(v)")

    ExUnit.CaptureLog.capture_log(fn ->
      assert_raise Runtime.Failure, fn -> run(plan, %{"v" => "private"}, event(store)) end
    end)

    refute_receive {:unexpected, _}, 10
  end

  test "one counter expression failure does not prevent its sibling's dispatch", %{store: store} do
    plan = plan("TRACK bad = sum(test_raise(v)) LAST '1h';
      TRACK good = count() LAST '1h'; UNSET secret")

    ExUnit.CaptureLog.capture_log(fn ->
      assert run(plan, %{"v" => "private", "secret" => "private"}, event(store)) ==
               %{"v" => "private", "bad" => nil, "good" => 1}
    end)
  end

  test "unexpected infrastructure exceptions default the level and still run final UNSET", %{
    store: store,
  } do
    plan = plan("TRACK hits = count() LAST '1h'; TRACK total = sum(v) LAST '1h';
      SET safe = hits = 0; UNSET secret")
    context = event(store)
    context = %{context | counters: %{context.counters | batch: :invalid_budget_handle}}

    ExUnit.CaptureLog.capture_log(fn ->
      assert run(plan, %{"v" => "private", "secret" => "private"}, context) ==
               %{"v" => "private", "hits" => 0, "total" => nil, "safe" => true}
    end)

    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "bucket merging remains chronological and retains the newest numeric tie type", %{
    store: store,
  } do
    for operator <- ["min", "max"] do
      definition = definition(plan("TRACK extreme = #{operator}(v) LAST '1h'"))
      context = event(store)
      current = Integer.floor_div(context.arrival_ms, definition.bucket_ms)

      assert :ok =
               Store.cas({definition.identity, {}, current - 1}, :missing, 1.0, 5_000,
                 server: store
               )

      assert CounterRuntime.track(definition, {}, [1], context) === 1

      assert CounterRuntime.lookup(definition, {}, context) === 1
      assert CounterRuntime.track(definition, {}, [1.0], event(store)) === 1.0
    end
  end

  test "CAS conflicts have three total attempts and uncertain writes are never retried" do
    definition = definition(plan("TRACK total = sum(v) LAST '1h'"))
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
      context =
        event(store, Guardian.Counters.Client.new_batch(), Event.arrival(), timeout_ms: 20)

      assert CounterRuntime.track(definition, {}, [5], context) == nil
      assert_receive :attempt

      if failure == :conflict do
        assert_receive :attempt
        assert_receive :attempt
      end

      refute_receive :attempt, 10
      stop_supervised!(ProbeStore)
      :ets.delete_all_objects(:rules_counter_runtime_test)
    end
  end

  test "a conflict retry refetches and merges the new current state" do
    definition = definition(plan("TRACK total = sum(v) LAST '1h'"))
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

    assert CounterRuntime.track(definition, {}, [5], event(store)) == 10
    assert_receive {:merged, 8}
    assert_receive {:merged, 10}
    assert Agent.get(attempt, & &1) == 2
  end

  test "a failed bucket defaults the whole result even when its parallel writer succeeds" do
    definition = definition(plan("TRACK hits = count() LAST '1h'"))
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

    assert CounterRuntime.track(definition, {}, [], event(store)) == 0
    assert_receive {:get, _}
    assert_receive {:incr, _, _, _}
  end

  test "TTL uses fixed expiry and decreases with elapsed private monotonic time" do
    definition = definition(plan("TRACK hits = count() LAST '1h'"))
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
    arrival = %{Event.arrival() | arrival_ms: 7_800_000}

    assert CounterRuntime.track(
             definition,
             {},
             [],
             event(store, Guardian.Counters.Client.new_batch(), arrival)
           ) == 1

    assert_receive {:ttl, first}
    assert first in 4_199_000..4_200_000
    older = %{arrival | monotonic_ms: arrival.monotonic_ms - 1_000}

    assert CounterRuntime.track(
             definition,
             {},
             [],
             event(store, Guardian.Counters.Client.new_batch(), older)
           ) == 1

    assert_receive {:ttl, second}
    assert (first - second) in 1_000..2_000
  end

  test "generic TRACK merges the state it successfully wrote without reading it back" do
    definition = definition(plan("TRACK total = sum(v) LAST '1h'"))
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

    context = event(store)

    expected_prior =
      Integer.floor_div(context.arrival_ms, definition.bucket_ms) -
        Integer.floor_div(context.arrival_ms - definition.window_ms, definition.bucket_ms)

    assert CounterRuntime.track(definition, {}, [5], context) == 8 + 2 * expected_prior
    for _ <- 1..expected_prior, do: assert_receive({:get, _})
    assert_receive {:gets, _}
    assert_receive {:cas, _, :token, 8, _}
    refute_receive {:gets, _}, 10
    refute_receive {:get, _}, 10
  end

  test "a slow gets cannot dispatch a CAS after fixed expiry" do
    definition = definition(plan("TRACK hits = sum(v) LAST '1s'"))
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
      Event.arrival()
      | arrival_ms: 0,
        monotonic_ms: System.monotonic_time(:millisecond) - 1_319,
    }

    assert CounterRuntime.track(
             definition,
             {},
             [5],
             event(store, Guardian.Counters.Client.new_batch(), arrival)
           ) == nil

    assert_receive {:gets, _}
    refute_receive {:cas, _, _, _, _}, 10
  end

  test "healthy large batches refund the budget and include every event", %{store: store} do
    definition = definition(plan("TRACK hits = count() LAST '1h'"))
    batch = Guardian.Counters.Client.new_batch()

    for n <- 1..300,
        do: assert(CounterRuntime.track(definition, {}, [], event(store, batch)) == n)

    assert :atomics.get(batch, 1) == 250_000
  end

  test "concurrent native increments never omit the event's own mutation", %{store: store} do
    definition = definition(plan("TRACK hits = count() LAST '1h'"))

    values =
      1..20
      |> Task.async_stream(fn _ -> CounterRuntime.track(definition, {}, [], event(store)) end,
        max_concurrency: 4
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.sort(values) == Enum.to_list(1..20)
    assert CounterRuntime.lookup(definition, {}, event(store)) == 20
  end

  test "many rules across events stop waiting when the failed-call batch allowance runs out" do
    parent = self()

    store =
      start_supervised!(
        {ProbeStore,
         {:pipeline,
          fn operations ->
            send(parent, :dispatched)
            Process.sleep(15)
            {:ok, Enum.map(operations, fn _ -> {:error, :evicted} end)}
          end}}
      )

    plan =
      plan(Enum.map_join(1..40, ";", &"TRACK c#{&1} = count() LAST '1h'") <> "; UNSET secret")

    batch = Guardian.Counters.Client.new_batch()
    started = System.monotonic_time(:millisecond)

    for _ <- 1..25 do
      row = run(plan, %{"secret" => "PRIVATE"}, event(store, batch))
      assert map_size(row) == 40
      assert Enum.all?(row, fn {_field, value} -> value == 0 end)
    end

    assert :atomics.get(batch, 1) < 10_000
    assert System.monotonic_time(:millisecond) - started < 1_000
    # Eight independent 100 ms phases could pass the elapsed-time check alone.
    # Shared 250 ms allowance permits at most 17 of these >=15 ms failed calls.
    assert drain_dispatches(0) in 1..17
  end

  test "concurrent generic CAS updates include their event or explicitly default on conflict", %{
    store: store,
  } do
    definition = definition(plan("TRACK total = sum(v) LAST '1h'"))

    values =
      1..30
      |> Task.async_stream(fn _ -> CounterRuntime.track(definition, {}, [1], event(store)) end,
        max_concurrency: 3
      )
      |> Enum.map(fn {:ok, value} -> value end)
      |> Enum.reject(&is_nil/1)

    assert length(values) > 0
    assert Enum.sort(values) == Enum.to_list(1..length(values))
    assert CounterRuntime.lookup(definition, {}, event(store)) == length(values)
  end

  defmodule MetadataRules do
    def apply(row, event) do
      send(
        Application.fetch_env!(:guardian, :counter_metadata_observer),
        {:metadata, self(), row, event}
      )

      if row["die"] do
        :atomics.sub(event.counters.batch, 1, 50_000)
        Process.exit(self(), :kill)
      end

      row
    end
  end

  test "Runner preserves batch reservations and arrival coordinates through worker replacement" do
    table = unique_table("counter_worker_metadata")
    publish_module(table, MetadataRules)
    put_env(:counter_metadata_observer, self())
    first = Event.arrival()
    second = %{first | arrival_ms: first.arrival_ms + 1}

    ExUnit.CaptureLog.capture_log(fn ->
      assert [{:error, _}, {:ok, %{"ok" => true}}] =
               Guardian.Rules.run_with_metadata(table, [
                 {%{"die" => true}, first},
                 {%{"ok" => true}, second},
               ])
    end)

    assert_receive {:metadata, first_worker, _, one}
    assert_receive {:metadata, second_worker, _, two}
    assert %Guardian.Counters.Context{} = one.counters
    assert %Guardian.Counters.Context{} = two.counters
    refute first_worker == second_worker
    assert one.arrival_ms == first.arrival_ms
    assert two.arrival_ms == second.arrival_ms
    assert one.monotonic_ms == two.monotonic_ms
    assert one.counters.batch == two.counters.batch
    assert :atomics.get(two.counters.batch, 1) == 200_000
    assert two.counters.members == [node() | Node.list()]
    assert two.counters.deadline > one.counters.deadline
  end

  test "Engine arrival metadata stays outside caller rows and is never stored" do
    table = unique_table("counter_engine_metadata")
    publish_module(table, MetadataRules)
    put_env(:counter_metadata_observer, self())
    spoofed = %{"arrival_ms" => 1, "monotonic_ms" => 1, "timestamp" => "old", "counters" => 99}
    before = System.system_time(:millisecond)

    assert [{:ok, ^spoofed}, {:error, "event is not a JSON object"}, {:ok, %{}}] =
             Guardian.Engine.ingest_events(table, [spoofed, false, %{}])

    assert_receive {:metadata, _, ^spoofed, private}
    assert private.arrival_ms >= before
    assert private.arrival_ms <= System.system_time(:millisecond)
    assert is_reference(private.counters.batch)
    assert_receive {:metadata, _, %{}, second}
    assert second.counters.batch == private.counters.batch
    assert MapSet.new(Guardian.Storage.dump_table(table)) == MapSet.new([spoofed, %{}])
    # The convenience entry captures its own private arrival and batch context.
    assert [{:ok, %{}}] = Guardian.Rules.run(table, [%{}])
    assert_receive {:metadata, _, %{}, direct}
    refute direct.counters.batch == private.counters.batch
  end

  defp drain_dispatches(n) do
    receive do
      :dispatched -> drain_dispatches(n + 1)
    after
      0 -> n
    end
  end
end

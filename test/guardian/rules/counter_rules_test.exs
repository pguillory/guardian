defmodule Guardian.Rules.CounterRulesTest do
  @moduledoc """
  TRACK and LOOKUP through Rules: rule plans run by `Guardian.Rules.Runtime` and
  compiled modules, Runner and Engine. Counter execution's own behavior (buckets,
  expiries, CAS, budgets) is tested in `Guardian.Counters.ExecutionTest`.
  """
  use ExUnit.Case, async: false
  import Guardian.Test.Rules
  alias Guardian.Aggregation
  alias Guardian.Counters.Arrival
  alias Guardian.Counters.Execution
  alias Guardian.Counters.LookupOperation
  alias Guardian.Counters.Store
  alias Guardian.Rules.DependencyGraph
  alias Guardian.Rules.Event
  alias Guardian.Rules.Runtime
  alias Guardian.Test.Counters.Budget, as: CounterBudgetHelper
  alias Guardian.Test.Counters.ProbeStore

  # No test here depends on the production 50 ms call or 100 ms event budget: the
  # allowance test depends on the 250 ms batch allowance. Larger budgets keep healthy
  # calls, including a cold first call, from timing out under host load and setting a
  # cooldown that fails later calls open.
  setup do
    Guardian.Test.Counters.relaxed_store(:rules_counter_rules_test)
  end

  defp event(store, batch \\ Guardian.Counters.Client.new_batch()) do
    Event.start(
      Arrival.now(),
      batch,
      Guardian.Test.Counters.event_options(store, :rules_counter_rules_test)
    )
  end

  # One LOOKUP straight through counter execution, unwrapped to its value.
  defp lookup(definition, group, event) do
    [{:ok, value}] =
      Execution.run_counters(
        [%LookupOperation{definition: definition, group: group}],
        event.arrival,
        event.counters
      )

    value
  end

  defp plans(files) do
    preparation = Guardian.Rules.RuleSet.prepare(files)
    assert preparation.errors == []
    Map.new(preparation.tables, fn {table, {:ok, plan}} -> {table, plan} end)
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
    |> Map.fetch!(:definition)
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

    assert CounterBudgetHelper.remaining_us(batch) == 250_000
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

  test "TRACK and LOOKUP write one column; columns beneath it stay", %{store: store} do
    rules = plan("TRACK hits = count() LAST '1h'; LOOKUP prior = hits")

    assert %{"hits" => 1, "hits.x" => 1, "prior" => 0, "prior.y" => 2} =
             run(rules, %{"hits.x" => 1, "prior.y" => 2}, event(store))
  end

  test "initial counter levels read inputs by exact name", %{store: store} do
    grouped = plan("TRACK hits = count() BY ip LAST '1h'")
    assert run(grouped, %{"ip" => "a"}, event(store))["hits"] == 1
    assert run(grouped, %{"ip" => "a"}, event(store))["hits"] == 2
    assert run(grouped, %{}, event(store))["hits"] == 1
    assert run(grouped, %{"IP" => "a"}, event(store))["hits"] == 2

    conditional = plan("TRACK hits = count() WHERE enabled LAST '1h';
      LOOKUP prior = hits WHERE enabled")

    assert run(conditional, %{"hits" => 99, "prior" => 98}, event(store)) ==
             %{"hits" => 99, "prior" => 98}

    assert run(conditional, %{"ENABLED" => true}, event(store)) == %{"ENABLED" => true}

    assert Map.take(run(conditional, %{"enabled" => true}, event(store)), ~w(hits prior)) ==
             %{"hits" => 1, "prior" => 0}

    aggregates = plan("TRACK present = count(v) LAST '1h'; TRACK total = sum(v) LAST '1h'")

    assert Map.take(run(aggregates, %{"v" => 3}, event(store)), ~w(present total)) ==
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
          identity: {plan.table, "missing", inspect(operator)},
      }

      assert lookup(defn, {}, event(store)) ==
               Aggregation.default(Aggregation.fetch!(name))
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
    current = Integer.floor_div(event(store).arrival.unix_ms, definition.bucket_ms)
    assert {:ok, nil} = Store.get({definition.identity, {}, current}, now(), server: store)
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
    current = Integer.floor_div(context.arrival.unix_ms, definition.bucket_ms)
    older = {definition.identity, {}, current - 1}
    assert :ok = Store.cas(older, :missing, {[9], 1}, 5_000, now(), server: store)

    # Unlike a failed bucket, a failed combination is reported as a rule warning.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Map.take(run(plan, %{"v" => 3, "k" => 2}, context), ~w(top hits)) ==
                 %{"top" => nil, "hits" => 3}
      end)

    assert log =~ "failed: Guardian.Query.Error"
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

  # A store that sends each dispatched batch to the test and answers as if empty.
  defp recording_store do
    parent = self()

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
  end

  test "each dependency level batches every counter and bucket into the longest machine's rounds" do
    store = recording_store()

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

  test "a compiled module runs a LOOKUP before its TRACK and batches the TRACK level", %{
    store: real_store,
  } do
    store = recording_store()

    plan =
      plan("""
      TRACK c = count() BY group_key LAST '1h';
      TRACK total = sum(v) LAST '1h';
      LOOKUP prior = c BY group_key;
      SET group_key = lower(ip);
      UNSET secret
      """)

    module = __MODULE__.LevelProbe

    compile_module(module, plan)

    row = apply(module, :apply, [%{"ip" => "A", "v" => 5, "secret" => "private"}, event(store)])

    assert row == %{
             "ip" => "A",
             "v" => 5,
             "group_key" => "a",
             "prior" => 0,
             "c" => 1,
             "total" => 5,
           }

    rounds =
      for _ <- 1..3 do
        assert_receive {:pipeline_ops, operations}
        operations
      end

    # The LOOKUP's bucket reads dispatch alone, before either TRACK; both TRACKs
    # then share one level's rounds.
    assert Enum.map(rounds, &length/1) == [4, 8, 1]
    assert Enum.all?(hd(rounds), &match?({:get, _}, &1))
    assert Enum.count(Enum.at(rounds, 1), &match?({:incr, _, _, _}, &1)) == 1
    assert Enum.count(Enum.at(rounds, 1), &match?({:gets, _}, &1)) == 1
    assert [{:cas, _, _, _, _}] = Enum.at(rounds, 2)
    refute_receive {:pipeline_ops, _}, 10

    # Against a real store, the LOOKUP and TRACK group on the SET's output.
    priors =
      for ip <- ~w(A A B) do
        apply(module, :apply, [%{"ip" => ip, "v" => 5}, event(real_store)])["prior"]
      end

    assert priors == [0, 1, 0]
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
    # A corrupt budget handle, and membership Transport's routing cannot hash (which it
    # does not rescue).
    for corrupt <- [[batch: :invalid_budget_handle], [members: []], [members: ["node"]]] do
      context = event(store)
      context = %{context | counters: struct!(context.counters, corrupt)}

      ExUnit.CaptureLog.capture_log(fn ->
        assert run(plan, %{"v" => "private", "secret" => "private"}, context) ==
                 %{"v" => "private", "hits" => 0, "total" => nil, "safe" => true}
      end)
    end

    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "many rules across events stop waiting when the failed-call batch allowance runs out" do
    # The allowance, not the call budget, stops these waits, so the relaxed budget does
    # not change what this checks. Under load a 15 ms failure could otherwise time out
    # at 50 ms and put the owner in cooldown, so later calls charge nothing.
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

    assert CounterBudgetHelper.remaining_us(batch) < 10_000
    # Guards against events waiting out their whole 900 ms event budgets (25 of them
    # would take over 20 s); it leaves room for host load.
    assert System.monotonic_time(:millisecond) - started < 2_500
    # Independent event phases could pass the elapsed-time check alone.
    # Shared 250 ms allowance permits at most 17 of these >=15 ms failed calls.
    assert drain_dispatches(0) in 1..17
  end

  defmodule MetadataRules do
    def apply(row, event) do
      send(
        Application.fetch_env!(:guardian, :counter_metadata_observer),
        {:metadata, self(), row, event}
      )

      if row["die"] do
        CounterBudgetHelper.charge_us(event.counters.batch, 50_000)
        Process.exit(self(), :kill)
      end

      row
    end
  end

  test "Runner preserves batch reservations and arrival coordinates through worker replacement" do
    table = unique_table("counter_worker_metadata")
    publish_module(table, MetadataRules)
    Guardian.Test.Env.put(counter_metadata_observer: self())
    first = Arrival.now()
    second = %{first | unix_ms: first.unix_ms + 1}

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
    assert one.arrival == first
    assert two.arrival == second
    assert one.arrival.monotonic_ms == two.arrival.monotonic_ms
    assert one.counters.batch == two.counters.batch
    assert CounterBudgetHelper.remaining_us(two.counters.batch) == 200_000
    assert two.counters.members == [node() | Node.list()]
    assert two.counters.deadline > one.counters.deadline
  end

  test "Engine arrival metadata stays outside caller rows and is never stored" do
    table = unique_table("counter_engine_metadata")
    publish_module(table, MetadataRules)
    Guardian.Test.Env.put(counter_metadata_observer: self())

    spoofed = %{
      "arrival" => 1,
      "unix_ms" => 1,
      "arrival_ms" => 1,
      "monotonic_ms" => 1,
      "timestamp" => "old",
      "counters" => 99,
    }

    before = System.system_time(:millisecond)

    assert [{:ok, ^spoofed}, {:error, "event is not a JSON object"}, {:ok, %{}}] =
             Guardian.Engine.ingest_events(table, [spoofed, false, %{}])

    assert_receive {:metadata, _, ^spoofed, private}
    assert private.arrival.unix_ms >= before
    assert private.arrival.unix_ms <= System.system_time(:millisecond)
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

  # Store operations take the current local monotonic milliseconds as data.
  defp now do
    System.monotonic_time(:millisecond)
  end
end

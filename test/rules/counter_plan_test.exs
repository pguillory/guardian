defmodule Rules.CounterPlanTest do
  use ExUnit.Case, async: true

  alias Rules.RuleSet

  defp plan(files, table \\ "t") do
    preparation = RuleSet.prepare(files)
    assert preparation.errors == []
    {:ok, plan} = preparation.tables[table]
    plan
  end

  defp previous(files) do
    preparation = RuleSet.prepare(files)
    assert preparation.errors == []
    Map.new(preparation.tables, fn {table, {:ok, plan}} -> {table, plan} end)
  end

  defp errors(source), do: RuleSet.prepare(%{"t/a.gsql" => source}).errors
  defp kinds(source), do: Enum.map(errors(source), & &1.kind)
  defp sources(plan), do: Enum.map(plan.steps, & &1.source)
  defp target(plan), do: Enum.find(plan.steps, &(&1.kind == :lookup)).target

  test "local candidates cannot compile, including SET-only and forged unbound LOOKUP plans" do
    for files <- [
          %{"t/a.gsql" => "SET x = 1; UNSET password"},
          %{"t/a.gsql" => "TRACK c = count() LAST '1h'; LOOKUP prior = c"},
        ] do
      preparation = RuleSet.prepare(files)
      assert preparation.errors == []
      {:ok, candidate} = preparation.candidates["t"]
      {:ok, resolved} = preparation.tables["t"]
      refute candidate.resolved?
      assert resolved.resolved?
      module = __MODULE__.CandidateProbe
      before = :code.is_loaded(module)
      assert Rules.Compiler.compile(module, candidate) == {:error, :unresolved_plan}
      assert :code.is_loaded(module) == before

      if Enum.any?(candidate.steps, &(&1.kind == :lookup)) do
        assert Rules.Compiler.compile(module, %{candidate | resolved?: true}) ==
                 {:error, :unbound_lookup}

        assert :code.is_loaded(module) == before
      end
    end
  end

  test "public validation reports every counter and scalar semantic error" do
    files = %{
      "t/a.gsql" => "SET x = count(); TRACK c = arbitrary(x) LAST '0s'",
      "u/a.gsql" => "SET x = 1",
    }

    preparation = RuleSet.prepare(files)

    assert Enum.sort(Enum.map(RuleSet.validate(files).errors, & &1.kind)) ==
             [:counter_aggregate, :counter_window, :expression]

    assert {:ok, %{resolved?: false}} = preparation.candidates["u"]
    assert {:ok, %{resolved?: true}} = preparation.tables["u"]
  end

  test "public validation produces resolved counter plans in barrier order" do
    files = %{"t/a.gsql" => "TRACK c = count() LAST '1h'; LOOKUP prior = c"}
    plan = plan(files)
    assert Enum.map(plan.steps, & &1.kind) == [:lookup, :track]
    assert RuleSet.validate(files).errors == []
    track_only = plan(%{"t/a.gsql" => "TRACK c = count() LAST '1h'"})

    lookup_only =
      plan(%{
        "a/r.gsql" => "TRACK c = count() LAST '1h'",
        "t/a.gsql" => "LOOKUP prior = c FROM a",
      })

    for single_kind <- [track_only, lookup_only] do
      assert single_kind.resolved?
      assert length(single_kind.steps) == 1
    end
  end

  test "counter operators are the aggregate allowlist, with scalar arguments" do
    for {name, arity} <- Counters.Aggregate.operators() do
      args = if arity == 0, do: "", else: "amount"
      [track] = plan(%{"t/a.gsql" => "TRACK c = #{name}(#{args}) LAST '1h'"}).steps
      assert track.operator == {name, arity}
    end

    assert kinds("TRACK c = arbitrary(x) LAST '1h'") == [:counter_aggregate]
    assert kinds("TRACK c = sum(count()) LAST '1h'") == [:expression]
    assert kinds("TRACK c = count() BY sum(x) LAST '1h'") == [:expression]
    assert kinds("TRACK c = count() WHERE avg(x) > 1 LAST '1h'") == [:expression]
    assert kinds("LOOKUP x = c BY sum(y)") == [:expression]
    assert kinds("LOOKUP x = c WHERE count() > 0") == [:expression]
    assert kinds("TRACK c = count(1, 2) LAST '1h'") == [:parse]
  end

  test "every non-scalar node is refused in SET values and all scalar input clauses" do
    for expr <- ["sum(x)", "*", "x AS y", "x ASC", "x DESC"],
        source <- [
          "SET a = #{expr}",
          "SET a = 1 WHERE #{expr}",
          "UNSET a WHERE #{expr}",
          "TRACK c = sum(#{expr}) LAST '1h'",
          "TRACK c = count() BY #{expr} LAST '1h'",
          "TRACK c = count() WHERE #{expr} LAST '1h'",
          "LOOKUP a = c BY #{expr}",
          "LOOKUP a = c WHERE #{expr}",
        ] do
      assert :expression in kinds(source), source
    end
  end

  test "LAST follows integral interval syntax with positive total and 365-day bound" do
    for {interval, expected, bucket} <- [
          {"1s", 1_000, 334},
          {"2m", 120_000, 40_000},
          {"1h 30m", 5_400_000, 1_800_000},
          {"1h -1m", 3_540_000, 1_180_000},
          {"+1d", 86_400_000, 28_800_000},
          {"52w 1d", 31_536_000_000, 10_512_000_000},
        ] do
      [track] = plan(%{"t/a.gsql" => "TRACK c = count() LAST '#{interval}'"}).steps
      assert track.window_ms == expected
      assert track.bucket_ms == bucket
    end

    for interval <- [
          "",
          " ",
          "0s",
          "-1s",
          "1h -1h",
          "1.5h",
          "1ms",
          "1y",
          "366d",
          "9223372036854775808s",
          "999999999999999999999999999999s",
        ] do
      assert kinds("TRACK c = count() LAST '#{interval}'") == [:counter_window], interval
    end
  end

  test "FROM validity, target kind and grouping arity are checked across tables" do
    for table <- ["queries", "bad-name", "bad/table"] do
      assert kinds("LOOKUP x = c FROM \"#{table}\"") == [:parse]
    end

    assert kinds("LOOKUP x = c FROM queries") == [:counter_table]
    assert kinds("LOOKUP x = c FROM #{String.duplicate("a", 65)}") == [:counter_table]
    assert kinds("LOOKUP x = c") == [:counter_target]
    assert kinds("SET c = 1; LOOKUP x = c") == [:counter_target]
    assert kinds("TRACK c = count() BY ip LAST '1h'; LOOKUP x = c") == [:counter_arity]

    files = %{
      "a/r.gsql" => "TRACK c = sum(amount) BY ip, region LAST '1h'",
      "t/a.gsql" => "LOOKUP x = c FROM a BY address, country",
    }

    lookup = hd(plan(files).steps)
    assert lookup.target.identity == hd(plan(files, "a").steps).identity
    assert lookup.target.operator == {"sum", 1}
    assert lookup.target.group_arity == 2
    assert lookup.reads == ["address", "country"]
  end

  test "output, counter and table names are not field dependency reads" do
    files = %{"t/a.gsql" => "TRACK c = sum(amount) BY group_key WHERE ok LAST '1h';
      LOOKUP prior = c BY group_key WHERE enabled; SET prior_copy = prior"}
    p = plan(files)
    lookup = Enum.find(p.steps, &(&1.kind == :lookup))
    track = Enum.find(p.steps, &(&1.kind == :track))
    assert lookup.reads == ["group_key", "enabled"]
    assert track.reads == ["amount", "group_key", "ok"]
    assert hd(p.steps).kind == :lookup

    assert errors("TRACK c = sum(c) BY c WHERE c > 0 LAST '1h'") == []
    assert errors("TRACK c = count() BY prior LAST '1h'; LOOKUP prior = c BY prior") == []
  end

  test "LOOKUPs and prerequisite SETs precede independent SETs and TRACKs; UNSET is last" do
    p = plan(%{"t/a.gsql" => "SET independent = 1; TRACK c = sum(amount) BY group_key LAST '1h';
      SET decision = c > prior; UNSET secret; LOOKUP prior = c BY group_key;
      SET group_key = normalized.ip; SET normalized = ip"})

    assert Enum.map(p.steps, & &1.field) ==
             ["normalized", "group_key", "prior", "independent", "c", "decision", "secret"]
  end

  test "barrier rejects direct and transitive TRACK reads in LOOKUP inputs" do
    for input <- ["BY c", "WHERE c > 0", "BY a", "WHERE a > 0"] do
      source = "TRACK c = count() BY ip LAST '1h'; SET a = b; SET b = c;
        LOOKUP prior = c #{input}"
      assert :counter_barrier in kinds(source)
    end

    assert kinds("TRACK c = sum(a) LAST '1h'; SET a = c") == [:cycle]

    assert :cycle in kinds(
             "TRACK c = count() BY prior LAST '1h'; LOOKUP prior = c BY a; SET a = prior"
           )
  end

  test "levels sort independent statements by location while retaining greedy flat metadata" do
    p =
      plan(%{
        "t/a.gsql" => "TRACK a = count() BY z LAST '1h'",
        "t/b.gsql" => "TRACK b = count() BY y LAST '1h'",
        "t/y.gsql" => "SET y = raw_y",
        "t/z.gsql" => "SET z = raw_z",
      })

    assert Enum.map(p.steps, & &1.field) == ["y", "b", "z", "a"]

    assert Enum.map(p.levels, fn level -> Enum.map(level, & &1.field) end) ==
             [["y", "z"], ["a", "b"]]
  end

  test "identical TRACK copies deduplicate and conflicts use the shared namespace" do
    files = %{
      "t/a.gsql" => "TRACK c = count(*) LAST '1h'",
      "t/b.gsql" => "-- comment\ntrack c=count() last '1h'",
    }

    assert length(plan(files).steps) == 1
    assert kinds("TRACK c = count() LAST '1h'; SET c = 1") == [:conflict]
    assert kinds("TRACK c = count() LAST '1h'; LOOKUP c = c") == [:conflict]
    assert kinds("TRACK c = count() LAST '1h'; UNSET c") == [:conflict]
    assert kinds("TRACK c = count() LAST '1h'; TRACK c = count() LAST '2h'") == [:conflict]
  end

  test "counter identities ignore location but include every canonical definition clause" do
    base = "TRACK c = sum(amount) BY ip WHERE ok LAST '1h'"
    [first] = plan(%{"t/a.gsql" => base}).steps
    moved = plan(%{"t/b.gsql" => "-- moved\n track c = SUM(amount) by ip where ok last '1h'"})
    assert hd(moved.steps).identity == first.identity

    for changed <- [
          String.replace(base, "sum", "max"),
          String.replace(base, "amount", "cost"),
          String.replace(base, "ip", "user"),
          String.replace(base, "WHERE ok", "WHERE enabled"),
          String.replace(base, "1h", "2h"),
          String.replace(base, "c =", "renamed ="),
        ] do
      refute hd(plan(%{"t/a.gsql" => changed}).steps).identity == first.identity
    end

    refute hd(plan(%{"u/a.gsql" => base}, "u").steps).identity == first.identity
  end

  test "dependent hashes bind target definitions but ignore target file and line" do
    files = %{
      "a/r.gsql" => "TRACK c = count() LAST '1h'",
      "t/a.gsql" => "LOOKUP prior = c FROM a",
    }

    first = plan(files)

    moved =
      files |> Map.delete("a/r.gsql") |> Map.put("a/moved.gsql", "\nTRACK c = count() LAST '1h'")

    assert plan(moved).hash == first.hash
    changed = Map.put(files, "a/r.gsql", "TRACK c = sum(amount) LAST '1h'")
    refute plan(changed).hash == first.hash
    assert target(first).operator == {"count", 0}
    assert target(plan(changed)).operator == {"sum", 1}
  end

  test "invalid targets propagate to a fixed point with stable repair errors" do
    files = %{
      "a/r.gsql" => "SET broken = count()",
      "b/r.gsql" => "TRACK c = count() LAST '1h'; LOOKUP prior = missing FROM a",
      "t/a.gsql" => "LOOKUP prior = c FROM b",
    }

    preparation = RuleSet.prepare(files)
    for table <- ["a", "b", "t"], do: assert(match?({:error, _}, preparation.tables[table]))
    changed = RuleSet.prepare(Map.put(files, "a/r.gsql", "\nSET other = sum(x)"))
    before = Enum.filter(preparation.errors, &(&1.table in ["b", "t"]))
    after_errors = Enum.filter(changed.errors, &(&1.table in ["b", "t"]))
    assert RuleSet.new_errors(before, after_errors) == []
    assert Rules.Activation.select(preparation).tables == preparation.tables
  end

  test "reciprocal cross-table references resolve by definition without execution edges" do
    files = %{
      "a/r.gsql" => "TRACK ca = count() LAST '1h'; LOOKUP prior = cb FROM b",
      "b/r.gsql" => "TRACK cb = count() LAST '1h'; LOOKUP prior = ca FROM a",
    }

    assert plan(files, "a").steps |> hd() |> Map.fetch!(:kind) == :lookup
    assert plan(files, "b").steps |> hd() |> Map.fetch!(:kind) == :lookup
    a = plan(files, "a")
    b = plan(files, "b")
    assert target(a).identity == Enum.find(b.steps, &(&1.kind == :track)).identity
    assert target(b).identity == Enum.find(a.steps, &(&1.kind == :track)).identity
  end

  test "SET/UNSET preparation and runtime selection preserve per-table behavior" do
    files = %{"a/r.gsql" => "SET x = 1; UNSET secret", "deleted/r.gsql" => "SET x = 2"}
    prep = RuleSet.prepare(files)

    assert elem(prep.tables["a"], 1).hash ==
             "85e505311172b4f3fe1fbaf62f395881dfefca3919a99962b54881b5ea23e6cd"

    old = previous(files)
    changed = RuleSet.prepare(%{"a/r.gsql" => "SET x = count()", "new/r.gsql" => "SET"})
    selected = Rules.Activation.select(changed, old)
    assert selected.tables["a"] == {:ok, old["a"]}
    assert {:error, _} = selected.tables["new"]
    refute Map.has_key?(selected.tables, "deleted")
    assert selected.retained == MapSet.new(["a"])
  end

  test "an invalid target retains its whole prior component while unrelated changes activate" do
    files = %{
      "a/r.gsql" => "TRACK c = count() LAST '1h'",
      "b/r.gsql" => "LOOKUP prior = c FROM a",
      "u/r.gsql" => "SET x = 1",
    }

    old = previous(files)

    changed =
      files
      |> Map.put("a/r.gsql", "TRACK c = count() LAST '0s'")
      |> Map.put("b/r.gsql", "LOOKUP renamed = c FROM a")
      |> Map.put("u/r.gsql", "SET x = 2")

    selected = Rules.Activation.select(RuleSet.prepare(changed), old)
    assert selected.tables["a"] == {:ok, old["a"]}
    assert selected.tables["b"] == {:ok, old["b"]}
    assert selected.retained == MapSet.new(["a", "b"])
    assert {:ok, unrelated} = selected.tables["u"]
    assert sources(unrelated) == ["SET x = 2"]
  end

  test "invalid dependents prevent changed operators, grouping or deleted targets from stranding identities" do
    files = %{
      "a/r.gsql" => "TRACK c = count() LAST '1h'",
      "b/r.gsql" => "LOOKUP prior = c FROM a",
    }

    old = previous(files)

    for target_source <- [
          "TRACK c = sum(amount) LAST '1h'",
          "TRACK c = count() BY ip LAST '1h'",
          "SET unrelated = 1",
          :delete,
        ] do
      changed =
        if target_source == :delete,
          do: Map.delete(files, "a/r.gsql"),
          else: Map.put(files, "a/r.gsql", target_source)

      # Both a syntactically invalid dependent and a valid old LOOKUP with an
      # invalid new target/grouping must roll back the same component.
      for dependent <- ["LOOKUP prior = c FROM a; SET", files["b/r.gsql"]] do
        prep = RuleSet.prepare(Map.put(changed, "b/r.gsql", dependent))

        if dependent == files["b/r.gsql"] and target_source == "TRACK c = sum(amount) LAST '1h'" do
          assert prep.errors == []
          selected = Rules.Activation.select(prep, old)
          assert {:ok, updated} = selected.tables["b"]
          assert target(updated).operator == {"sum", 1}
          refute updated.hash == old["b"].hash
        else
          refute prep.errors == []
          selected = Rules.Activation.select(prep, old)
          assert selected.tables["a"] == {:ok, old["a"]}
          assert selected.tables["b"] == {:ok, old["b"]}
        end
      end
    end
  end

  test "retention defers deleted dependents too, while a fully valid deletion removes them" do
    files = %{
      "a/r.gsql" => "TRACK c = count() LAST '1h'",
      "b/r.gsql" => "LOOKUP prior = c FROM a",
    }

    old = previous(files)
    invalid = files |> Map.delete("b/r.gsql") |> Map.put("a/r.gsql", "SET")
    selected = Rules.Activation.select(RuleSet.prepare(invalid), old)
    assert selected.tables["b"] == {:ok, old["b"]}
    assert selected.tables["a"] == {:ok, old["a"]}
    valid = Map.delete(files, "b/r.gsql")
    refute Map.has_key?(Rules.Activation.select(RuleSet.prepare(valid), old).tables, "b")
    assert Rules.Activation.select(RuleSet.prepare(%{}), old).tables == %{}
  end

  test "boot invalidity is directed; runtime refuses new valid targets in a retained component" do
    files = %{
      "a/r.gsql" => "TRACK c = count() LAST '1h'",
      "b/r.gsql" => "LOOKUP prior = c FROM a BY ip",
      "u/r.gsql" => "SET x = 1",
    }

    preparation = RuleSet.prepare(files)
    assert {:ok, _} = Rules.Activation.select(preparation).tables["a"]
    assert {:error, _} = preparation.tables["b"]
    old = previous(%{"u/r.gsql" => "SET x = 1"})
    selected = Rules.Activation.select(preparation, old)
    assert {:error, [%{kind: :reload_dependency}]} = selected.tables["a"]
    assert {:error, [%{kind: :counter_arity}]} = selected.tables["b"]
  end

  test "new dependents joining a retained component are invalid until a coherent reload" do
    files = %{
      "a/r.gsql" => "TRACK c = count() LAST '1h'",
      "b/r.gsql" => "LOOKUP prior = c FROM a",
    }

    old = previous(files)

    changed =
      files
      |> Map.put("b/r.gsql", "SET")
      |> Map.put("a/r.gsql", "TRACK c = sum(amount) LAST '1h'")
      |> Map.put("new/r.gsql", "LOOKUP prior = c FROM a")

    selected = Rules.Activation.select(RuleSet.prepare(changed), old)
    assert {:error, [%{kind: :reload_dependency, message: message}]} = selected.tables["new"]
    assert message =~ "component (b)"
    assert selected.tables["a"] == {:ok, old["a"]}
    repaired = Map.put(changed, "b/r.gsql", "LOOKUP prior = c FROM a")
    selected = Rules.Activation.select(RuleSet.prepare(repaired), old)
    assert selected.retained == MapSet.new()
    assert {:ok, new} = selected.tables["new"]
    assert target(new).operator == {"sum", 1}
  end

  test "old and candidate edges jointly retain cascaded components, independent of table names" do
    for [a, b, c] <- [["a", "b", "c"], ["z", "m", "a"]] do
      files = %{
        "#{a}/r.gsql" => "TRACK ca = count() LAST '1h'",
        "#{b}/r.gsql" => "TRACK cb = count() LAST '1h'; LOOKUP pa = ca FROM #{a}",
        "#{c}/r.gsql" => "LOOKUP pb = cb FROM #{b}",
      }

      old = previous(files)

      changed =
        files
        |> Map.delete("#{a}/r.gsql")
        |> Map.put("#{c}/r.gsql", "LOOKUP renamed = cb FROM #{b}")

      prep = RuleSet.prepare(changed)
      assert {:error, _} = prep.tables[b]
      assert {:error, _} = prep.tables[c]
      selected = Rules.Activation.select(prep, old)
      assert selected.retained == MapSet.new([a, b, c])
      for table <- [a, b, c], do: assert(selected.tables[table] == {:ok, old[table]})
    end
  end

  test "retargeting a LOOKUP connects old and new target components during retention" do
    files = %{
      "a/r.gsql" => "TRACK ca = count() LAST '1h'",
      "b/r.gsql" => "LOOKUP prior = ca FROM a",
      "c/r.gsql" => "TRACK cc = count() LAST '1h'",
    }

    old = previous(files)

    changed =
      files
      |> Map.put("a/r.gsql", "SET")
      |> Map.put("b/r.gsql", "LOOKUP prior = cc FROM c")
      |> Map.put("c/r.gsql", "TRACK cc = sum(amount) LAST '1h'")

    preparation = RuleSet.prepare(changed)
    assert {:ok, _} = preparation.tables["b"]
    selected = Rules.Activation.select(preparation, old)
    assert selected.retained == MapSet.new(["a", "b", "c"])
    for table <- ["a", "b", "c"], do: assert(selected.tables[table] == {:ok, old[table]})
  end

  test "target invalidity crosses three locally valid dependency levels" do
    files = %{
      "a/r.gsql" => "TRACK ca = count() LAST '0s'",
      "b/r.gsql" => "TRACK cb = count() LAST '1h'; LOOKUP pa = ca FROM a",
      "c/r.gsql" => "TRACK cc = count() LAST '1h'; LOOKUP pb = cb FROM b",
      "d/r.gsql" => "LOOKUP pc = cc FROM c",
    }

    preparation = RuleSet.prepare(files)

    for table <- ["b", "c", "d"] do
      assert {:ok, _} = preparation.candidates[table]
      assert {:error, [%{kind: :counter_target}]} = preparation.tables[table]
    end
  end

  test "disjoint retained components report only their own failure causes" do
    files = %{
      "a/r.gsql" => "TRACK ca = count() LAST '1h'",
      "x/r.gsql" => "LOOKUP prior = ca FROM a",
      "b/r.gsql" => "TRACK cb = count() LAST '1h'",
      "y/r.gsql" => "LOOKUP prior = cb FROM b",
    }

    old = previous(files)

    changed =
      files
      |> Map.put("x/r.gsql", "SET")
      |> Map.put("y/r.gsql", "SET")
      |> Map.put("new_a/r.gsql", "LOOKUP prior = ca FROM a")
      |> Map.put("new_b/r.gsql", "LOOKUP prior = cb FROM b")

    selected = Rules.Activation.select(RuleSet.prepare(changed), old)
    assert {:error, [%{message: a_cause}]} = selected.tables["new_a"]
    assert {:error, [%{message: b_cause}]} = selected.tables["new_b"]
    assert a_cause =~ "component (x)"
    assert b_cause =~ "component (y)"
    assert selected.retained == MapSet.new(["a", "b", "x", "y"])
  end

  test "a present valid table connected only by a prior edge retains its prior plan" do
    files = %{
      "a/r.gsql" => "TRACK c = count() LAST '1h'",
      "b/r.gsql" => "LOOKUP prior = c FROM a",
    }

    old = previous(files)
    changed = files |> Map.put("a/r.gsql", "SET") |> Map.put("b/r.gsql", "SET x = 2")
    preparation = RuleSet.prepare(changed)
    assert {:ok, _} = preparation.tables["b"]
    selected = Rules.Activation.select(preparation, old)
    assert selected.tables["b"] == {:ok, old["b"]}
  end
end

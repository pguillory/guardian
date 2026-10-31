defmodule Guardian.Rules.CounterReloadTest do
  # Not async: relaxes the node-wide counter budgets.
  use ExUnit.Case, async: false
  import Guardian.Test.Rules

  setup do
    # No test here is about budgets: a larger one keeps healthy counter calls from
    # timing out under load.
    Guardian.Test.Counters.Budget.relax()
    :ok
  end

  # Makes the store hold `files`, of the files this test has loaded, and reloads.
  defp load(files) do
    for key <- Process.get(:loaded, []), not Map.has_key?(files, key) do
      File.rm!(rule_path(key))
    end

    for {key, source} <- files, do: plant_file(key, source)
    Process.put(:loaded, Map.keys(files))
    assert :ok = Guardian.Rules.reload()
  end

  defp ingest(table, event \\ %{}) do
    assert [{:ok, row}] = Guardian.Engine.ingest_events(table, [event])
    row
  end

  defp plan(files, table) do
    {:ok, plan} = Guardian.Rules.RuleSet.prepare(files).tables[table]
    plan
  end

  defp target(files, table) do
    Enum.find(plan(files, table).steps, &(&1.kind == :lookup)).target
  end

  defp identity(files, table) do
    Enum.find(plan(files, table).steps, &(&1.kind == :track)).definition.identity
  end

  test "valid edits switch target and dependent identities; in-flight old modules keep old state" do
    a = unique_table("live_target")
    b = unique_table("live_dependent")

    files = %{
      "#{a}/r.gsql" => "TRACK hits = count() LAST '1h'",
      "#{b}/r.gsql" => "LOOKUP prior = hits FROM #{a}",
    }

    load(files)
    old_files = files
    old_a = Guardian.Rules.lookup(a)
    old_b = Guardian.Rules.lookup(b)
    assert ingest(a)["hits"] == 1
    assert ingest(b)["prior"] == 1

    files = Map.put(files, "#{a}/r.gsql", "TRACK hits = sum(amount) LAST '1h'")
    load(files)
    new_a = Guardian.Rules.lookup(a)
    new_b = Guardian.Rules.lookup(b)
    refute new_a == old_a
    refute new_b == old_b
    assert new_b.hash() == plan(files, b).hash
    assert target(files, b).identity == identity(files, a)
    refute target(files, b).identity == target(old_files, b).identity
    assert ingest(b)["prior"] == nil
    assert ingest(a, %{"amount" => 7})["hits"] == 7
    assert ingest(b)["prior"] == 7
    assert old_a.apply(%{})["hits"] == 2
    assert old_b.apply(%{})["prior"] == 2
    assert ingest(b)["prior"] == 7

    # Locations affect recompilation, but not the counter's definition identity.
    moved =
      files
      |> Map.delete("#{a}/r.gsql")
      |> Map.put("#{a}/moved.gsql", "-- moved\nTRACK hits = sum(amount) LAST '1h'")

    load(moved)
    assert identity(moved, a) == identity(files, a)
    assert ingest(a, %{"amount" => 3})["hits"] == 10
    assert ingest(b)["prior"] == 10
  end

  test "a reload that finds an invalid target fails it and its dependents; others activate" do
    a = unique_table("invalid_target")
    b = unique_table("invalid_target_reader")
    join = unique_table("new_reader")
    other = unique_table("counter_unrelated")
    deleted = unique_table("counter_deleted")

    files = %{
      "#{a}/r.gsql" => "TRACK hits = count() LAST '1h'",
      "#{b}/r.gsql" => "LOOKUP prior = hits FROM #{a}",
      "#{other}/r.gsql" => "SET value = 1",
      "#{deleted}/r.gsql" => "SET value = 1",
    }

    load(files)
    assert ingest(a)["hits"] == 1

    changed =
      files
      |> Map.put("#{a}/r.gsql", "TRACK hits = count() LAST '0s'")
      |> Map.put("#{other}/r.gsql", "SET value = 2")
      |> Map.delete("#{deleted}/r.gsql")
      |> Map.put("#{join}/r.gsql", "LOOKUP prior = hits FROM #{a}")

    load(changed)
    for table <- [a, b, join], do: assert({:invalid, _} = Guardian.Rules.lookup(table))
    assert [{:error, "rules for " <> _}] = Guardian.Engine.ingest_events(b, [%{}])
    assert ingest(other)["value"] == 2
    assert Guardian.Rules.lookup(deleted) == nil

    # Repairing the target restores the same counter definition, so the count goes on.
    load(Map.put(changed, "#{a}/r.gsql", files["#{a}/r.gsql"]))
    assert ingest(a)["hits"] == 2
    assert ingest(b)["prior"] == 2
    assert ingest(join)["prior"] == 2
  end

  test "an invalid dependent fails alone while its target changes, regroups or goes" do
    for source <- [
          "TRACK hits = sum(amount) LAST '1h'",
          "TRACK hits = count() BY ip LAST '1h'",
          "TRACK renamed = count() LAST '1h'",
          nil,
        ] do
      a = unique_table("changed_target")
      b = unique_table("invalid_reader")
      join = unique_table("joining_reader")

      files = %{
        "#{a}/r.gsql" => "TRACK hits = count() LAST '1h'",
        "#{b}/r.gsql" => "LOOKUP prior = hits FROM #{a}",
      }

      load(files)
      changed = Map.put(files, "#{b}/r.gsql", "LOOKUP prior = hits FROM #{a}; SET")

      changed =
        if source,
          do: Map.put(changed, "#{a}/r.gsql", source),
          else: Map.delete(changed, "#{a}/r.gsql")

      counter = if source && source =~ "renamed", do: "renamed", else: "hits"
      group = if source && source =~ "BY ip", do: " BY ip", else: ""
      changed = Map.put(changed, "#{join}/r.gsql", "LOOKUP prior = #{counter} FROM #{a}#{group}")
      load(changed)
      assert {:invalid, _} = Guardian.Rules.lookup(b)

      if source do
        assert Guardian.Rules.lookup(a).hash() == plan(changed, a).hash
        assert Guardian.Rules.lookup(join).hash() == plan(changed, join).hash
      else
        assert Guardian.Rules.lookup(a) == nil
        assert {:invalid, _} = Guardian.Rules.lookup(join)
      end
    end
  end

  @tag :lifecycle
  test "boot and reload publish the same result for the same invalid files" do
    a = unique_table("same_target")
    b = unique_table("same_invalid_reader")
    c = unique_table("same_transitive_reader")

    files = %{
      "#{a}/r.gsql" => "TRACK ca = count() LAST '1h'",
      "#{b}/r.gsql" => "TRACK cb = count() LAST '1h'; LOOKUP bad = ca FROM #{a} BY ip",
      "#{c}/r.gsql" => "LOOKUP bad = cb FROM #{b}",
    }

    load(Map.put(files, "#{b}/r.gsql", "TRACK cb = count() LAST '1h'"))
    load(files)
    reloaded = Map.take(Guardian.Rules.published(), [a, b, c])

    assert {:ok, _} = restart_server()

    booted = Map.take(Guardian.Rules.published(), [a, b, c])
    assert booted[a].hash() == reloaded[a].hash()
    assert {:invalid, _} = booted[b]
    assert {:invalid, _} = booted[c]
    assert Map.take(booted, [b, c]) == Map.take(reloaded, [b, c])
    assert ingest(a)["ca"] == 1
    assert [{:error, _}] = Guardian.Engine.ingest_events(c, [%{}])
  end

  test "dependent name and arity migrations use a new counter then retarget before deleting" do
    a = unique_table("migration_target")
    b = unique_table("migration_reader")

    load(%{
      "#{a}/r.gsql" => "TRACK hits = count() LAST '1h'",
      "#{b}/r.gsql" => "LOOKUP prior = hits FROM #{a}",
    })

    assert {:error, {:rejected, _}} =
             Guardian.Rules.write_rule(a, "r", "TRACK hits = count() BY ip LAST '1h'")

    assert {:error, {:rejected, _}} = Guardian.Rules.delete_rule(a, "r")

    assert {:ok, _} =
             Guardian.Rules.write_rule(a, "new", "TRACK grouped = count() BY ip LAST '1h'")

    assert ingest(a, %{"ip" => "a"})["grouped"] == 1
    assert {:ok, _} = Guardian.Rules.write_rule(b, "r", "LOOKUP prior = grouped FROM #{a} BY ip")
    assert {:ok, _} = Guardian.Rules.delete_rule(a, "r")
    assert ingest(b, %{"ip" => "a"})["prior"] == 1
  end
end

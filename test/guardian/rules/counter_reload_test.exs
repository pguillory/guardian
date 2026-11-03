defmodule Guardian.Rules.CounterReloadTest do
  use ExUnit.Case, async: true
  import Guardian.Test.Rules

  defp write(table, name, source) do
    assert {:ok, %{errors: []}} = Guardian.Rules.write_rule(table, name, source)
  end

  # Deletes the dependent's rules before the target's, which a write would refuse
  # the other way round.
  defp delete_on_exit(files) do
    on_exit(fn ->
      for {table, name} <- files, do: Guardian.Rules.delete_rule(table, name)
    end)
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

  test "valid edits switch target and dependent identities" do
    a = unique_table("live_target")
    b = unique_table("live_dependent")
    delete_on_exit([{b, "r"}, {a, "r"}, {a, "moved"}])

    files = %{
      "#{a}/r.gsql" => "TRACK hits = count() LAST '1h'",
      "#{b}/r.gsql" => "LOOKUP prior = hits FROM #{a}",
    }

    write(a, "r", files["#{a}/r.gsql"])
    write(b, "r", files["#{b}/r.gsql"])
    old_files = files
    assert ingest(a)["hits"] == 1
    assert ingest(b)["prior"] == 1

    files = Map.put(files, "#{a}/r.gsql", "TRACK hits = sum(amount) LAST '1h'")
    write(a, "r", files["#{a}/r.gsql"])
    new_b = Guardian.Rules.lookup(b)
    assert Guardian.Rules.lookup(a).hash() == plan(files, a).hash
    refute plan(files, b).hash == plan(old_files, b).hash
    assert new_b.hash() == plan(files, b).hash
    assert target(files, b).identity == identity(files, a)
    refute target(files, b).identity == target(old_files, b).identity
    assert ingest(b)["prior"] == nil
    assert ingest(a, %{"amount" => 7})["hits"] == 7
    assert ingest(b)["prior"] == 7

    # Locations affect recompilation, but not the counter's definition identity.
    moved =
      files
      |> Map.delete("#{a}/r.gsql")
      |> Map.put("#{a}/moved.gsql", "-- moved\nTRACK hits = sum(amount) LAST '1h'")

    write(a, "moved", moved["#{a}/moved.gsql"])
    assert {:ok, _} = Guardian.Rules.delete_rule(a, "r")
    assert identity(moved, a) == identity(files, a)
    assert ingest(a, %{"amount" => 3})["hits"] == 10
    assert ingest(b)["prior"] == 10
  end

  test "dependent name and arity migrations use a new counter then retarget before deleting" do
    a = unique_table("migration_target")
    b = unique_table("migration_reader")
    delete_on_exit([{b, "r"}, {a, "r"}, {a, "new"}])
    write(a, "r", "TRACK hits = count() LAST '1h'")
    write(b, "r", "LOOKUP prior = hits FROM #{a}")

    assert {:error, {:rejected, _}} =
             Guardian.Rules.write_rule(a, "r", "TRACK hits = count() BY ip LAST '1h'")

    assert {:error, {:rejected, _}} = Guardian.Rules.delete_rule(a, "r")
    write(a, "new", "TRACK grouped = count() BY ip LAST '1h'")
    assert ingest(a, %{"ip" => "a"})["grouped"] == 1
    write(b, "r", "LOOKUP prior = grouped FROM #{a} BY ip")
    assert {:ok, _} = Guardian.Rules.delete_rule(a, "r")
    assert ingest(b, %{"ip" => "a"})["prior"] == 1
  end
end

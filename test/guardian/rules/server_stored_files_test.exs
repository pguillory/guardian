defmodule Guardian.Rules.ServerStoredFilesTest do
  # Not async: plants invalid files, which every concurrent write's reply would report,
  # and one test makes the folder unreadable.
  use ExUnit.Case, async: false
  import Guardian.Test.Rules

  test "a folder is read like a bucket: stray files are ignored, misplaced rules are errors" do
    nested = unique_table("rules_nested")
    good = unique_table("rules_good")

    for {key, body} <- [
          {"x.gsql", "SET x = 1"},
          {"#{nested}/sub/a.gsql", "SET x = 1"},
          {"#{nested}/a.gsql", "SET x = 1"},
          {"#{good}/a.gsql", "SET x = 1"},
          {"#{good}/notes.txt", "not a rule"},
          {"README", "not a rule"},
        ] do
      plant_file(key, body)
    end

    assert Guardian.Rules.reload() == :ok

    # The nested file makes its table invalid; the root file names no table.
    assert {:invalid, _} = Guardian.Rules.lookup(nested)
    assert (module = Guardian.Rules.lookup(good)) != nil and is_atom(module)
    assert Guardian.Rules.list_rules(good) == {:ok, [%{table: good, name: "a", size: 9}]}

    # Existing errors do not block a write, which reports them.
    assert {:ok, %{errors: errors}} = Guardian.Rules.write_rule(good, "b", "SET y = 2")
    assert Enum.any?(errors, &String.starts_with?(&1, "x.gsql"))
    assert Enum.any?(errors, &String.starts_with?(&1, "#{nested}/sub/a.gsql"))
    assert Guardian.Rules.lookup(good) not in [nil, module]
  end

  test "a broken stored set can be repaired one file at a time; other tables stay writable" do
    table = unique_table("rules_repair")
    other = unique_table("rules_other")
    remove_on_exit(other)
    plant_file("#{table}/a.gsql", "SET x = nosuch(1)")
    plant_file("#{table}/b.gsql", "SET y = nosuch(2)")
    assert Guardian.Rules.reload() == :ok
    assert {:invalid, _} = Guardian.Rules.lookup(table)

    assert {:ok, %{errors: [remaining]}} =
             Guardian.Rules.write_rule(table, "a", "-- moved\nSET x = 1")

    assert remaining =~ "#{table}/b.gsql"
    assert {:ok, _} = Guardian.Rules.write_rule(other, "a", "SET z = 1")
    assert {:ok, %{errors: []}} = Guardian.Rules.delete_rule(table, "b")
    assert is_atom(Guardian.Rules.lookup(table))
  end

  test "a reload that finds a table's stored copy invalid fails its events" do
    table = unique_table("rules_turned_invalid")
    other = unique_table("rules_still_valid")
    remove_on_exit(table)
    remove_on_exit(other)
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    {:ok, _} = Guardian.Rules.write_rule(other, "a", "SET x = 1")
    plant_file("#{table}/a.gsql", "SET x = ")
    assert Guardian.Rules.reload() == :ok
    assert {:invalid, _} = Guardian.Rules.lookup(table)

    assert [{:error, message}] = Guardian.Engine.ingest_events(table, [%{}])
    assert message =~ "rules for #{table} are invalid"

    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(other, [%{}])
    assert {:ok, [_]} = Guardian.Rules.list_rules(table)
  end

  test "writing an unrelated table activates a broken stored table as invalid and reports it once" do
    table = unique_table("rules_broken")
    other = unique_table("rules_unrelated")
    remove_on_exit(table)
    remove_on_exit(other)
    assert {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1; UNSET password")
    plant_file("#{table}/a.gsql", "SET x = nosuch(1)")

    assert {:ok, %{errors: [error], unconfirmed: []}} =
             Guardian.Rules.write_rule(other, "a", "SET x = 2")

    assert error == "#{table}/a.gsql line 1: Invalid function nosuch"

    assert Guardian.Rules.lookup(table) ==
             {:invalid, "#{table}/a.gsql line 1: Invalid function nosuch"}

    assert [{:error, _}] = Guardian.Engine.ingest_events(table, [%{"password" => "hide"}])
    assert [{:ok, %{"x" => 2}}] = Guardian.Engine.ingest_events(other, [%{}])
  end

  test "a rejected write does not hide rules another writer saved from the next reload" do
    table = unique_table("rules_cache")
    plant_file("#{table}/a.gsql", "SET x = 1")

    assert {:error, {:rejected, [_conflict]}} = Guardian.Rules.write_rule(table, "b", "SET x = 2")
    assert :ok = Guardian.Rules.reload()
    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(table, [%{}])
  end

  test "a misnamed rule file makes its table invalid instead of dropping its rules" do
    table = unique_table("rules_misnamed")
    remove_on_exit(table)
    assert {:ok, _} = Guardian.Rules.write_rule(table, "a", "UNSET password")
    plant_file("#{table}/B.gsql", "UNSET password")

    assert :ok = Guardian.Rules.reload()
    assert {:invalid, _message} = Guardian.Rules.lookup(table)
    assert [{:error, _}] = Guardian.Engine.ingest_events(table, [%{"password" => "p"}])
  end

  test "a failed reload is an error and the node keeps its rules" do
    table = unique_table("rules_failed_reload")
    remove_on_exit(table)
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    module = Guardian.Rules.lookup(table)
    folder = rule_path("")
    File.chmod!(folder, 0o000)
    on_exit(fn -> File.chmod(folder, 0o755) end)

    assert {:error, message} = Guardian.Rules.reload()
    assert message =~ "eacces"
    assert Guardian.Rules.lookup(table) == module
    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(table, [%{}])
  end

  test "an oversized stored file is an error" do
    table = unique_table("rules_big")
    plant_file("#{table}/a.gsql", String.duplicate(" ", 70_000))
    assert :ok = Guardian.Rules.reload()
    assert {:invalid, "#{table}/a.gsql: is over 65536 bytes"} == Guardian.Rules.lookup(table)
  end
end

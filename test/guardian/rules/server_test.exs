defmodule Guardian.Rules.ServerTest do
  use ExUnit.Case, async: true
  import Guardian.Test.Rules

  test "a rejected write saves nothing and lists every new error" do
    table = unique_table("rules_reject")
    on_exit(fn -> Guardian.Rules.delete_rule(table, "a") end)

    assert {:error, {:rejected, [message]}} =
             Guardian.Rules.write_rule(table, "a", "SET x = count()")

    assert message == "#{table}/a.gsql line 1: rules cannot use aggregate functions"
    assert Guardian.Rules.list_rules(table) == {:ok, []}

    assert {:ok, %{errors: [], unconfirmed: []}} =
             Guardian.Rules.write_rule(table, "a", "SET x = 1")

    assert {:error, {:rejected, [conflict]}} = Guardian.Rules.write_rule(table, "b", "SET x = 2")
    assert conflict =~ "x is defined differently"
    assert Guardian.Rules.list_rules(table) == {:ok, [%{table: table, name: "a", size: 9}]}
    assert Guardian.Rules.read_rule(table, "a") == {:ok, "SET x = 1"}
    assert {:error, "no rule file " <> _} = Guardian.Rules.delete_rule(table, "nope")
    assert {:ok, _} = Guardian.Rules.delete_rule(table, "a")
    assert Guardian.Rules.lookup(table) == nil
  end

  test "a written rule is readable, listed and runs; deleted, it is gone" do
    table = unique_table("rules_stored")
    other = unique_table("rules_stored_other")
    with_rules(%{"#{table}/a.gsql" => "SET x = 1", "#{other}/a.gsql" => "SET y = 2"})

    assert Guardian.Rules.read_rule(table, "a") == {:ok, "SET x = 1"}
    assert Guardian.Rules.list_rules(table) == {:ok, [%{table: table, name: "a", size: 9}]}
    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(table, [%{}])

    assert {:ok, %{errors: []}} = Guardian.Rules.delete_rule(table, "a")

    assert Guardian.Rules.read_rule(table, "a") == {:error, "no rule file #{table}/a.gsql"}
    assert Guardian.Rules.list_rules(table) == {:ok, []}
    assert Guardian.Engine.ingest_events(table, [%{}]) == [{:ok, %{}}]

    # Other tables keep their rules.
    assert Guardian.Rules.read_rule(other, "a") == {:ok, "SET y = 2"}
    assert [{:ok, %{"y" => 2}}] = Guardian.Engine.ingest_events(other, [%{}])
  end

  test "a published module carries its plan's table and hash, including regex and scalar literals" do
    table = unique_table("rules_metadata")

    source =
      "SET x = message RLIKE '^secret$'; SET y = CASE WHEN x THEN 'yes' ELSE 'no' END; UNSET password"

    with_rules(%{"#{table}/a.gsql" => source})
    module = Guardian.Rules.lookup(table)

    assert {:ok, expected} =
             Guardian.Rules.RuleSet.validate(%{"#{table}/a.gsql" => source}).tables[table]

    assert module.hash() == expected.hash
    assert module.table() == expected.table

    assert module.apply(%{"message" => "secret", "password" => "hide"}) ==
             %{"message" => "secret", "x" => true, "y" => "yes"}
  end

  test "a rewrite replaces the table's one module in place" do
    table = unique_table("rules_swap")
    on_exit(fn -> Guardian.Rules.delete_rule(table, "a") end)
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 0")
    module = Guardian.Rules.lookup(table)
    assert module == Guardian.Rules.Compiler.module_name(table)
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    assert Guardian.Rules.lookup(table) == module
    assert module.apply(%{}) == %{"x" => 1}
  end

  test "a table whose rules were all deleted runs new rules once written again" do
    table = unique_table("rules_rewrite")
    on_exit(fn -> Guardian.Rules.delete_rule(table, "b") end)
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 0")
    {:ok, _} = Guardian.Rules.delete_rule(table, "a")
    assert Guardian.Engine.ingest_events(table, [%{}]) == [{:ok, %{}}]

    {:ok, _} = Guardian.Rules.write_rule(table, "b", "SET y = 1")
    assert [{:ok, %{"y" => 1} = row}] = Guardian.Engine.ingest_events(table, [%{}])
    refute Map.has_key?(row, "x")
  end

  # The one test that parks a process inside rule code (CONTRIBUTING.md's testing
  # philosophy otherwise keeps tests out of processes): rules finish in milliseconds,
  # so nothing else can still be running a module's old code at the next write.
  test "a write while an event runs the replaced rules changes nothing" do
    table = unique_table("rules_too_recent")
    on_exit(fn -> Guardian.Rules.delete_rule(table, "a") end)
    parked = park_in_rules_module(table)
    on_exit(fn -> send(parked, :release) end)
    # This write replaces the parked module, leaving the process in old code.
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")

    assert Guardian.Rules.write_rule(table, "a", "SET x = 2") ==
             {:error, "rules changed too recently; try again"}

    assert Guardian.Rules.read_rule(table, "a") == {:ok, "SET x = 1"}
    assert [{:ok, %{"x" => 1}}] = Guardian.Engine.ingest_events(table, [%{}])
    # A write that leaves the table's rules unchanged loads nothing, so it goes through.
    assert {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")

    ref = Process.monitor(parked)
    send(parked, :release)
    assert_receive {:DOWN, ^ref, :process, ^parked, :normal}
    assert {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 2")
    assert [{:ok, %{"x" => 2}}] = Guardian.Engine.ingest_events(table, [%{}])
  end

  test "a failed save or delete is an error that says so and releases the lock" do
    table = unique_table("rules_failed_save")
    with_rules(%{"#{table}/a.gsql" => "SET x = 1"})
    on_exit(fn -> Guardian.Rules.delete_rule(table, "b") end)
    module = Guardian.Rules.lookup(table)
    folder = rule_path(table)
    File.chmod!(folder, 0o500)
    on_exit(fn -> File.chmod(folder, 0o755) end)

    for result <- [
          Guardian.Rules.write_rule(table, "b", "SET y = 2"),
          Guardian.Rules.delete_rule(table, "a"),
        ] do
      assert {:error, message} = result
      assert message =~ "eacces"
      assert message =~ "may have been saved"
    end

    assert Guardian.Rules.lookup(table) == module
    File.chmod!(folder, 0o755)
    # A lock left behind would make this :busy for two minutes.
    assert {:ok, _} = Guardian.Rules.write_rule(table, "b", "SET y = 2")
  end
end

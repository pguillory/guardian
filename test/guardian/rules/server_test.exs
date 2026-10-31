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

  test "an old module stays callable until it is reclaimed" do
    table = unique_table("rules_hold")
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 0")
    held = Guardian.Rules.lookup(table)
    {:ok, _} = Guardian.Rules.write_rule(table, "a", "SET x = 1")
    {:ok, _} = Guardian.Rules.delete_rule(table, "a")
    assert held.apply(%{}) == %{"x" => 0}
    assert Guardian.Rules.lookup(table) == nil
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

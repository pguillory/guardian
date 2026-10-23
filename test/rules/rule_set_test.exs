defmodule Rules.RuleSetTest do
  use ExUnit.Case, async: true

  alias Rules.RuleSet

  defp messages(files),
    do: files |> RuleSet.validate() |> Map.fetch!(:errors) |> Enum.map(& &1.message)

  defp steps(files, table) do
    {:ok, plan} = RuleSet.validate(files).tables[table]
    Enum.map(plan.steps, & &1.source)
  end

  test "a valid set gives each table its statements, SETs in dependency order, UNSETs last" do
    files = %{
      "logins/a.gsql" => "UNSET card_number; SET b = a + 1",
      "logins/b.gsql" => "SET a = 1 WHERE c; SET has_card = card_number IS NOT NULL",
      "orders/x.gsql" => "SET z = 1",
    }

    assert messages(files) == []

    assert steps(files, "logins") == [
             "SET a = 1 WHERE c",
             "SET b = a + 1",
             "SET has_card = card_number IS NOT null",
             "UNSET card_number",
           ]

    assert steps(files, "orders") == ["SET z = 1"]
  end

  test "dependencies count reads in WHERE and of nested paths" do
    files = %{"t/a.gsql" => "SET x = 1 WHERE y.z > 0; SET y = 2"}
    assert steps(files, "t") == ["SET y = 2", "SET x = 1 WHERE y.z > 0"]
  end

  test "identical duplicates are one definition, a self-read is not a cycle" do
    files = %{
      "t/a.gsql" => "SET n = n + 1; SET email = lower(email)",
      "t/b.gsql" => "set  n=n+1 -- same\n",
    }

    assert messages(files) == []
    assert steps(files, "t") == ["SET n = n + 1", "SET email = lower(email)"]
  end

  test "rejects a field defined two different ways, including SET with UNSET" do
    assert messages(%{"t/a.gsql" => "SET x = 1", "t/b.gsql" => "SET x = 1 WHERE y"}) == [
             "t/b.gsql line 1: x is defined differently here and in t/a.gsql line 1",
           ]

    assert messages(%{"t/a.gsql" => "SET x = 1\n;UNSET x"}) == [
             "t/a.gsql line 2: x is defined differently here and in t/a.gsql line 1",
           ]

    # Different tables are independent.
    assert messages(%{"t/a.gsql" => "SET x = 1", "u/a.gsql" => "SET x = 2"}) == []
  end

  test "rejects cycles" do
    assert messages(%{"t/a.gsql" => "SET a = b", "t/b.gsql" => "SET b = c; SET c = a"}) == [
             "t/a.gsql line 1: rules read each other's fields in a cycle: a, b, c",
           ]
  end

  test "rejects aggregates and other non-scalar expressions anywhere" do
    assert messages(%{"t/a.gsql" => "SET a = count()"}) == [
             "t/a.gsql line 1: rules cannot use aggregate functions",
           ]

    assert messages(%{"t/a.gsql" => "UNSET a WHERE sum(x) > 1"}) == [
             "t/a.gsql line 1: rules cannot use aggregate functions",
           ]

    assert messages(%{"t/a.gsql" => "SET a = b AS c"}) == ["t/a.gsql line 1: rules cannot use AS"]
  end

  test "rejects parse errors, bad paths, built-in tables and oversized files" do
    assert messages(%{
             "t/a.gsql" => "SET = 1",
             "Bad/a.gsql" => "",
             "queries/a.gsql" => "SET a = 1",
             "t/UPPER.gsql" => "",
             "t/big.gsql" => String.duplicate(" ", 64 * 1024 + 1),
             "t/c/d.gsql" => "",
             "README.md" => "ignored",
             "_write.lock" => "ignored",
           }) == [
             "Bad/a.gsql: " <> Exception.message(%Engine.InvalidTableNameError{table: "Bad"}),
             "queries/a.gsql: queries is a built-in table; rules run only on ingested events",
             "t/UPPER.gsql: rule file names must match [a-z0-9_][a-z0-9_-]* and be at most 64 bytes",
             "t/a.gsql line 1: Expected field name, got =",
             "t/big.gsql: is over 65536 bytes",
             "t/c/d.gsql: a rule file must be <table>/<name>.gsql",
           ]
  end

  test "a misnamed file in a table's folder is an error for that table" do
    validation = RuleSet.validate(%{"t/a.gsql" => "SET x = 1", "t/A.gsql" => ""})
    assert {:error, [%{file: "t/A.gsql", kind: :path}]} = validation.tables["t"]
    assert RuleSet.validate(%{"Bad/a.gsql" => ""}).tables == %{}
  end

  test "deleting the first of three conflicting definitions adds no new error" do
    files = %{"t/a.gsql" => "SET x = 1", "t/b.gsql" => "SET x = 2", "t/c.gsql" => "SET x = 3"}
    before = RuleSet.validate(files).errors
    after_delete = RuleSet.validate(Map.delete(files, "t/a.gsql")).errors
    assert [%{file: "t/c.gsql", kind: :conflict}] = after_delete
    assert RuleSet.new_errors(before, after_delete) == []
  end

  test "a plan's hash covers file and line, so moved statements recompile" do
    {:ok, plan} = RuleSet.validate(%{"t/a.gsql" => "SET x = 1"}).tables["t"]
    {:ok, moved} = RuleSet.validate(%{"t/a.gsql" => "\nSET x = 1"}).tables["t"]
    refute plan.hash == moved.hash
  end

  test "an error in one table leaves the others valid" do
    validation = RuleSet.validate(%{"t/a.gsql" => "SET", "u/a.gsql" => "SET x = 1"})
    assert {:error, [_]} = validation.tables["t"]
    assert {:ok, %Rules.Plan{}} = validation.tables["u"]
  end

  test "new_errors ignores lines, so moving a broken statement is not a new error" do
    before = RuleSet.validate(%{"t/a.gsql" => "SET x = nosuch(1)"}).errors
    moved = RuleSet.validate(%{"t/a.gsql" => "-- comment\n\nSET x = nosuch(1)"}).errors
    assert RuleSet.new_errors(before, moved) == []
    added = RuleSet.validate(%{"t/a.gsql" => "SET x = nosuch(1)", "t/b.gsql" => "SET"}).errors
    assert [%{file: "t/b.gsql"}] = RuleSet.new_errors(before, added)
  end

  test "limits on statements per table" do
    source = Enum.map_join(1..1001, ";", &"SET f#{&1} = 1")
    assert messages(%{"t/a.gsql" => source}) == ["t/a.gsql: t has more than 1000 statements"]
  end
end

defmodule Guardian.Rules.IngestTest do
  # Not async: with_rules writes the shared rule store and tests set the application env.
  use ExUnit.Case, async: false
  import Guardian.Test.Rules

  defp ingest(table, events) do
    Guardian.Engine.ingest_events(table, events)
  end

  test "SET computes fields before storage; the reported event and stored row include them" do
    table = unique_table("rules_set")

    with_rules(%{
      "#{table}/blocking.gsql" => """
      SET is_blocked = true WHERE signal > 0.9;
      SET is_suspicious = true WHERE lower(message) LIKE '%wire transfer%';
      SET severity = CASE WHEN status >= 500 THEN 'high' ELSE 'low' END
      """,
    })

    assert [{:ok, first}, {:ok, second}] =
             ingest(table, [
               %{"signal" => 0.97, "message" => "Please WIRE TRANSFER now", "status" => 503},
               %{"signal" => 0.1, "message" => "hi", "status" => 200},
             ])

    assert first == %{
             "signal" => 0.97,
             "message" => "Please WIRE TRANSFER now",
             "status" => 503,
             "is_blocked" => true,
             "is_suspicious" => true,
             "severity" => "high",
           }

    assert second == %{"signal" => 0.1, "message" => "hi", "status" => 200, "severity" => "low"}

    assert {:ok, ["is_blocked", "severity"], rows} =
             Guardian.Query.execute(
               "SELECT is_blocked, severity FROM #{table} ORDER BY signal DESC"
             )

    assert rows == [[true, "high"], [nil, "low"]]
  end

  test "NOT IN in a rule's WHERE sets the field for values outside the list only" do
    table = unique_table("rules_not_in")

    with_rules(%{
      "#{table}/allow.gsql" =>
        "SET allowed = true WHERE ip NOT IN ['203.0.113.9', '198.51.100.7']",
    })

    assert [{:ok, listed}, {:ok, other}, {:ok, missing}] =
             ingest(table, [%{"ip" => "203.0.113.9"}, %{"ip" => "192.0.2.1"}, %{"n" => 1}])

    assert listed == %{"ip" => "203.0.113.9"}
    assert other == %{"ip" => "192.0.2.1", "allowed" => true}
    assert missing == %{"n" => 1}
  end

  test "UNSET removes exactly the named column; SETs read it first" do
    table = unique_table("rules_unset")

    with_rules(%{
      "#{table}/strip.gsql" => """
      SET has_card = card_number IS NOT NULL;
      UNSET card_number;
      UNSET password;
      UNSET users..email;
      UNSET user.secret WHERE env = 'prod'
      """,
    })

    event = %{
      "card_number" => "4111",
      "Password" => "a",
      "password" => %{"hash" => "b"},
      "users" => [%{"email" => "e", "id" => 1}],
      "user" => %{"name" => "bob", "secret" => %{"x" => 1}, "Secret" => 2},
      "env" => "prod",
    }

    assert [{:ok, reported}] = ingest(table, [event])
    assert reported["Password"] == "a"
    assert reported["password"] == %{"hash" => "b"}
    assert reported["users"] == [%{"id" => 1}]

    assert Guardian.Storage.dump_table(table) == [
             %{
               "has_card" => true,
               "Password" => "a",
               "password.hash" => "b",
               "users..id" => [1],
               "user.name" => "bob",
               "user.secret.x" => 1,
               "user.Secret" => 2,
               "env" => "prod",
             },
           ]

    # WHERE false leaves the field as sent.
    assert [{:ok, %{"user" => %{"secret" => 1}}}] =
             ingest(table, [%{"user" => %{"secret" => 1}, "env" => "dev"}])

    assert [{:ok, reported}] = ingest(table, [%{"user" => %{"secret" => 1}, "env" => "prod"}])
    assert reported == %{"has_card" => false, "env" => "prod"}
  end

  test "SET writes the one column it names, and columns beneath it stay" do
    table = unique_table("rules_flat_set")

    with_rules(%{
      "#{table}/r.gsql" => "SET user = 'redacted'; SET tags = 'none'; SET email = lower(Email)",
    })

    assert [{:ok, reported}] =
             ingest(table, [
               %{"user" => %{"name" => "Bob"}, "tags" => [%{"a" => 1}], "Email" => "A@B.COM"},
             ])

    assert Guardian.Storage.dump_table(table) == [
             %{
               "user" => "redacted",
               "user.name" => "Bob",
               "tags" => "none",
               "tags..a" => [1],
               "email" => "a@b.com",
               "Email" => "A@B.COM",
             },
           ]

    # A top-level field with columns beneath it cannot be one JSON value, so the result
    # leaves it out and return_keys reads it as null. Other fields are unaffected.
    assert %{"email" => "a@b.com", "Email" => "A@B.COM"} = reported
    refute Map.has_key?(reported, "user")
    refute Map.has_key?(reported, "tags")
  end

  test "reads: unknown fields are null, names match exactly" do
    table = unique_table("rules_reads")

    with_rules(%{
      "#{table}/r.gsql" => """
      SET a = missing IS NULL;
      SET b = Status;
      SET c = 1 WHERE missing > 1;
      SET d = user.name;
      SET e = User.Name
      """,
    })

    assert [{:ok, one}, {:ok, two}] =
             ingest(table, [
               %{"Status" => 1, "STATUS" => 2, "User" => %{"Name" => "x"}},
               %{"status" => 3},
             ])

    assert %{"a" => true, "b" => 1, "d" => nil, "e" => "x"} = one
    refute Map.has_key?(one, "c")
    assert %{"b" => nil} = two
  end

  test "rules that all skip leave an event alone, whatever its keys" do
    table = unique_table("rules_skip_keys")
    with_rules(%{"#{table}/r.gsql" => "SET x = 1 WHERE false; UNSET y WHERE false"})
    # Guardian.Storage.Flattening cannot decode this key's flattened form; no skipped rule
    # may decode it.
    event = %{"a.\\" => 1, "b" => 2}
    assert [{:ok, ^event}] = ingest(table, [event])
  end

  test "values a rule produces are validated like incoming ones" do
    table = unique_table("rules_invalid_value")
    # A field name over Guardian.Storage.Value.max_key_size/0 bytes cannot be stored.
    long_name = String.duplicate("k", Guardian.Storage.Value.max_key_size() + 1)
    with_rules(%{"#{table}/r.gsql" => "SET #{long_name} = 1; SET ok = 1"})
    assert [{:ok, reported}] = ingest(table, [%{"x" => 1}])
    assert reported == %{"x" => 1, "ok" => 1}
    assert Guardian.Storage.dump_table(table) == [%{"x" => 1, "ok" => 1}]
  end

  test "arithmetic with no good value stores null, and integer overflow wraps" do
    table = unique_table("rules_numeric")
    with_rules(%{"#{table}/r.gsql" => "SET x = div(a, 0); SET y = a * 2; SET z = sqrt(-a)"})
    assert [{:ok, reported}] = ingest(table, [%{"a" => 9_223_372_036_854_775_807}])
    assert reported == %{"a" => 9_223_372_036_854_775_807, "x" => nil, "y" => -2, "z" => nil}
    assert Guardian.Storage.dump_table(table) == [%{"a" => 9_223_372_036_854_775_807, "y" => -2}]
  end

  test "a statement that raises fails its event (fail closed), naming the file and line" do
    table = unique_table("rules_raise")
    # No real function raises; test_raise/1 (test build only) does on any value.
    with_rules(%{"#{table}/r.gsql" => "SET ok = 1;\nSET x = test_raise(a)"})
    secret = "secret-#{System.unique_integer([:positive])}"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [{:error, message}, {:ok, %{"ok" => 1, "b" => 1}}] =
                 ingest(table, [%{"a" => secret}, %{"b" => 1}])

        assert message =~ "rule #{table}/r.gsql line 2 failed"
        assert message =~ "the event was not stored"
        refute message =~ secret
      end)

    refute log =~ secret
    assert Guardian.Storage.dump_table(table) == [%{"b" => 1, "ok" => 1}]
  end

  test "a regular expression past its backtracking limit gives null, not a failure" do
    table = unique_table("rules_regex_limit")

    with_rules(%{
      "#{table}/r.gsql" => "SET x = a RLIKE '(a+)+$'; SET y = replace(a, '(a+)+$', '')",
    })

    evil = String.duplicate("a", 5_000) <> "b"
    assert [{:ok, reported}] = ingest(table, [%{"a" => evil}])
    assert %{"x" => nil, "y" => nil} = reported
    assert Guardian.Storage.dump_table(table) == [%{"a" => evil}]
  end

  defmodule SlowRules do
    def apply(row, _event) do
      apply(row)
    end

    def apply(%{"sleep" => ms} = row) do
      Process.sleep(ms)
      row
    end

    def apply(%{"big" => n} = row) do
      Map.put(row, "list", Enum.to_list(1..n))
    end

    def apply(%{"raise" => secret}) do
      raise("boom #{secret}")
    end

    def apply(row) do
      Map.put(row, "ran", true)
    end
  end

  test "an event over its time or heap limit fails alone; outcomes stay in order" do
    table = unique_table("rules_limits")
    publish_module(table, SlowRules)
    Guardian.Test.Env.put(rules_time_limit_ms: 200, query_max_heap_mb: 4)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [ok1, slow, ok2, big, raised, ok3] =
                 ingest(table, [
                   %{"n" => 1},
                   %{"sleep" => 5_000},
                   %{"n" => 2},
                   %{"big" => 10_000_000},
                   %{"raise" => "SECRET-VALUE"},
                   %{"n" => 3},
                 ])

        assert {:ok, %{"n" => 1, "ran" => true}} = ok1

        assert {:error,
                "rules for #{table} exceeded their time or memory limit; the event was not stored"} ==
                 slow

        assert {:ok, %{"n" => 2, "ran" => true}} = ok2

        assert {:error,
                "rules for #{table} exceeded their time or memory limit; the event was not stored"} ==
                 big

        assert {:error, "rules for #{table} failed (RuntimeError); the event was not stored"} ==
                 raised

        assert {:ok, %{"n" => 3, "ran" => true}} = ok3
      end)

    refute log =~ "SECRET-VALUE"

    assert table |> Guardian.Storage.dump_table() |> Enum.map(& &1["n"]) |> Enum.sort() == [
             1,
             2,
             3,
           ]
  end

  test "a table whose stored rules are invalid fails its events; other tables are unaffected" do
    table = unique_table("rules_invalid_table")
    publish_module(table, {:invalid, "#{table}/r.gsql line 1: Expected field name"})

    assert [{:error, message}] = ingest(table, [%{"x" => 1}])

    assert message ==
             "rules for #{table} are invalid (#{table}/r.gsql line 1: Expected field name); the event was not stored"

    assert Guardian.Storage.dump_table(table) == []

    other = unique_table("rules_other")
    assert [{:ok, %{"x" => 1}}] = ingest(other, [%{"x" => 1}])
  end

  test "non-object events and tables without rules behave as before" do
    table = unique_table("rules_mixed")
    with_rules(%{"#{table}/r.gsql" => "SET y = 2"})

    assert [{:ok, %{"x" => 1, "y" => 2}}, {:error, "event is not a JSON object"}] =
             ingest(table, [%{"x" => 1}, 5])
  end

  test "an event with a key ending in a backslash is stored when a rule changes a field" do
    table = unique_table("rules_backslash_key")
    with_rules(%{"#{table}/r.gsql" => "SET y = 2"})

    assert [{:ok, %{"a.\\" => 1, "y" => 2}}] = ingest(table, [%{"a.\\" => 1}])
    assert {:ok, ["y"], [[2]]} = Guardian.Query.execute("SELECT y FROM #{table}")
  end

  test "a table Guardian writes itself takes rules, which run on API ingests but never on Guardian's own writes" do
    marker = unique_table("rules_own_writes")
    with_rules(%{"queries/#{marker}.gsql" => "SET rule_ran = true WHERE marker = '#{marker}'"})

    assert {:ok, rules} = Guardian.Rules.list_rules("queries")
    assert Enum.any?(rules, &(&1.name == marker))

    assert {:ok, "SET rule_ran = true" <> _} = Guardian.Rules.read_rule("queries", marker)
    assert :ok = Guardian.Rules.reload()
    module = Guardian.Rules.lookup("queries")
    assert is_atom(module) and not is_nil(module)

    Guardian.Engine.log_event("queries", %{marker: marker, source: "own"})

    assert [{:ok, %{"rule_ran" => true}}] =
             ingest("queries", [%{"marker" => marker, "source" => "api"}])

    assert {:ok, ["source", "rule_ran"], [["api", true], ["own", nil]]} =
             Guardian.Query.execute(
               "SELECT source, rule_ran FROM queries WHERE marker = '#{marker}' ORDER BY source"
             )

    assert {:ok, _} = Guardian.Rules.delete_rule("queries", marker)
  end

  test "HTTP and MCP ingest return computed fields through return_keys, null when missing" do
    table = unique_table("rules_api")
    with_rules(%{"#{table}/r.gsql" => "SET is_blocked = true WHERE signal > 0.9"})

    assert {:ok, %{status: 200, results: results}} =
             Guardian.Web.Ingest.send_events(%{
               "table" => table,
               "events" => [%{"signal" => 0.97}, %{"signal" => 0.1}],
               "return_keys" => ["is_blocked"],
             })

    assert results == [
             %{success: true, event: %{"is_blocked" => true}},
             %{success: true, event: %{"is_blocked" => nil}},
           ]
  end
end

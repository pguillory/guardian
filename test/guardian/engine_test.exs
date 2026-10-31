defmodule Guardian.EngineTest do
  use ExUnit.Case, async: true
  import Guardian.Test.Tables, only: [unique_table: 1]
  import Guardian.Engine

  test "ingests storage-safe event values without transformation" do
    table = "engine_ingest_#{System.unique_integer([:positive])}"

    event = %{
      "name" => "alice",
      "score" => 10,
      "invalid" => self(),
    }

    assert ingest_event(table, event) == %{
             "name" => "alice",
             "score" => 10,
           }

    assert Guardian.Storage.dump_table(table) == [%{"name" => "alice", "score" => 10}]
  end

  test "drops invalid nested values and keeps their siblings" do
    table = "engine_nested_#{System.unique_integer([:positive])}"
    long_key = String.duplicate("k", 250)

    event = %{
      "a" => %{"b" => 2 ** 64, "c" => 1},
      "x" => [%{"a" => [[1]], "b" => 2}, %{"b" => 3}],
      "deep" => %{long_key => 1, "ok" => true},
      "dotted.key" => %{"q\"uote" => "v"},
      "items" => [%{"id" => 1, "tags" => ["t"]}, %{"id" => 2}],
    }

    # The returned row is exactly what Storage stores: flat columns, with the invalid
    # values (an integer over 64 bits, a list of lists of lists, a 250-byte key) left
    # out. A list of objects is one list column per key, padded with nil up to the last
    # object that has the key.
    expected = %{
      "a.c" => 1,
      "x..b" => [2, 3],
      "deep.ok" => true,
      ~S("dotted.key"."q\"uote") => "v",
      "items..id" => [1, 2],
      "items..tags" => [["t"]],
    }

    assert ingest_event(table, event) == expected
    assert Guardian.Storage.dump_table(table) == [expected]
  end

  test "stores arrays mixing scalars, objects, and lists" do
    table = "engine_mixed_#{System.unique_integer([:positive])}"

    events = [
      %{"x" => [1, %{"a" => 2}], "y" => 1},
      %{"x" => [[%{"a" => 1}], 2]},
      %{"x" => [%{"a" => 1}, [%{"a" => 2}]]},
    ]

    for event <- events do
      flat_row = Guardian.Storage.Flattening.flatten_event(event)
      assert ingest_event(table, event) == flat_row
      assert flat_row in Guardian.Storage.dump_table(table)
    end
  end

  test "drops an invalid value from an array mixing scalars and objects" do
    table = "engine_mixed_invalid_#{System.unique_integer([:positive])}"
    event = %{"x" => [1, %{"a" => 2, "b" => 2 ** 64}], "y" => 1}

    expected = %{"x" => [1], "x..a" => [nil, 2], "y" => 1}
    assert ingest_event(table, event) == expected
    assert Guardian.Storage.dump_table(table) == [expected]
  end

  test "merges nested objects whose keys collide as strings" do
    table = "engine_key_collision_#{System.unique_integer([:positive])}"
    event = %{"x" => %{"b" => 2}, x: %{a: 1}}

    assert ingest_event(table, event) == %{"x.a" => 1, "x.b" => 2}
    assert Guardian.Storage.dump_table(table) == [%{"x.a" => 1, "x.b" => 2}]

    event = %{"x" => [%{"b" => 2}], x: [%{a: 1}]}
    assert ingest_event(table, event) == %{"x..a" => [1], "x..b" => [2]}
    assert %{"x..a" => [1], "x..b" => [2]} in Guardian.Storage.dump_table(table)
  end

  test "stores long strings and lists whole" do
    table = "engine_long_values_#{System.unique_integer([:positive])}"
    string = String.duplicate("z", 100_000)
    list = Enum.to_list(1..70_000)
    event = %{"s" => string, "l" => list, "nested" => %{"s" => string}}

    expected = %{"s" => string, "l" => list, "nested.s" => string}
    assert ingest_event(table, event) == expected
    assert Guardian.Storage.dump_table(table) == [expected]
  end

  test "returns atom keys as strings, as they are stored" do
    table = "engine_atom_keys_#{System.unique_integer([:positive])}"
    expected = %{"user.name" => "Alice", "count" => 1, "xs" => [1], "xs..a" => [nil, 2]}

    assert ingest_event(table, %{
             user: %{name: "Alice"},
             count: 1,
             xs: [1, %{a: 2}],
           }) ==
             expected

    assert ingest_event(table, %{
             user: %{name: "Alice"},
             count: 1,
             xs: [1, %{a: 2}],
             bad: self(),
           }) ==
             expected
  end

  test "keeps nested values that are valid" do
    table = "engine_valid_nested_#{System.unique_integer([:positive])}"
    event = %{"user" => %{"name" => "Alice", "roles" => ["a", "b"]}, "n" => nil}

    assert ingest_event(table, event) == %{
             "user.name" => "Alice",
             "user.roles" => ["a", "b"],
             "n" => nil,
           }
  end

  test "returns only what was stored, so empty objects and lists are absent" do
    table = "engine_empty_#{System.unique_integer([:positive])}"
    event = %{"o" => %{}, "l" => [], "x" => %{"inner" => %{}}, "n" => 1}
    assert ingest_event(table, event) == %{"n" => 1}
    assert ingest_events(table, [event]) == [{:ok, %{"n" => 1}}]
  end

  test "ingests batches" do
    table = "engine_batch_#{System.unique_integer([:positive])}"
    events = [%{"value" => 1}, %{"value" => 2}]

    assert ingest_events(table, events) == Enum.map(events, &{:ok, &1})
    assert Guardian.Storage.dump_table(table) == events
  end

  test "batch outcomes preserve input order and continue after non-object events" do
    table = unique_table("engine_outcomes")
    first = %{"value" => 1}
    last = %{"value" => 2}

    assert ingest_events(table, [first, nil, 42, "bad", [], last]) == [
             {:ok, first},
             {:error, "event is not a JSON object"},
             {:error, "event is not a JSON object"},
             {:error, "event is not a JSON object"},
             {:error, "event is not a JSON object"},
             {:ok, last},
           ]

    assert Guardian.Storage.dump_table(table) == [first, last]
    assert ingest_events(table, []) == []
    # Exercise invalid input at runtime without a compile-time type warning.
    assert_raise FunctionClauseError, fn ->
      apply(Guardian.Engine, :ingest_event, [table, nil])
    end
  end

  test "an unexpected raise fails the whole batch; events before it stay stored" do
    table = unique_table("engine_outcomes")

    assert_raise FunctionClauseError, fn ->
      ingest_events(table, [%{"value" => 1}, %{{:bad} => 2}, %{"value" => 3}])
    end

    assert Guardian.Storage.dump_table(table) == [%{"value" => 1}]
  end

  @valid_table_names [
    "a",
    "_",
    "_a",
    "z9",
    "a_b_1",
    "system_stats",
    "web_requests",
    "web_responses",
    "selected",
    "schemas",
    String.duplicate("a", 64),
  ]

  # Names SQL cannot address: it has no "-" in a name and starts a number at a leading
  # digit; reserved words never parse as table names.
  @sql_unaddressable_table_names [
    "my-events",
    "-a",
    "1a",
    "9",
    "select",
    "SELECT",
    "from",
    "insert",
    "into",
    "values",
    "desc",
    "tables",
    "day",
    "null",
    "true",
    "false",
    "current_date",
    "current_timestamp",
    "schema",
  ]

  # Addressable, since identifiers keep their case, but table names are lowercase.
  @uppercase_table_names ["MyEvents", "A"]

  @unsafe_table_names [
    "",
    "a.b",
    ".",
    "..",
    "../escape",
    "a/b",
    "/abs",
    "a\\b",
    "a b",
    "é",
    "a\0b",
    "a\n",
    nil,
    :atom,
    123,
  ]

  describe "table names" do
    test "accepts lowercase SQL identifiers" do
      for table <- @valid_table_names do
        assert valid_table_name?(table), table
      end
    end

    test "rejects names that SQL cannot address" do
      for table <- @sql_unaddressable_table_names ++ @uppercase_table_names do
        refute valid_table_name?(table), inspect(table)
      end
    end

    test "rejects names over 64 bytes, which could not be persisted" do
      refute valid_table_name?(String.duplicate("a", 65))
      refute valid_table_name?(String.duplicate("a", 200))

      error =
        assert_raise Guardian.Engine.InvalidTableNameError, fn ->
          ingest_event(String.duplicate("a", 200), %{"v" => 1})
        end

      assert Exception.message(error) =~ "at most 64 characters"
    end

    test "rejects names that are unsafe in segment filenames" do
      for table <- @unsafe_table_names do
        refute valid_table_name?(table), inspect(table)
      end
    end

    test "every accepted name parses back as the same SQL table reference" do
      for table <- @valid_table_names do
        assert {:ok,
                [
                  %Guardian.AST.Node.Statements.SelectStatement{
                    from_expr: %Guardian.AST.Node.Identifier{name: ^table},
                  },
                ]} =
                 Guardian.AST.parse_statements("SELECT x FROM #{table}")

        assert {:ok,
                [
                  %Guardian.AST.Node.Statements.DescStatement{
                    expr: %Guardian.AST.Node.Identifier{name: ^table},
                  },
                ]} =
                 Guardian.AST.parse_statements("DESC #{table}")
      end
    end

    test "rejected names do not parse back as the same SQL table reference" do
      for table <- @sql_unaddressable_table_names do
        refute same_table_reference?(table), inspect(table)
      end
    end

    test "invalid names raise before anything is written" do
      id = System.unique_integer([:positive])

      for table <- [
            "engine_bad_#{id}.x",
            "engine_bad_#{id}/x",
            "../engine_bad_#{id}",
            "",
            "engine-bad-#{id}",
            "Engine_bad_#{id}",
          ] do
        assert_raise Guardian.Engine.InvalidTableNameError, ~r/invalid table name/, fn ->
          ingest_event(table, %{"v" => 1})
        end

        assert_raise Guardian.Engine.InvalidTableNameError, fn ->
          ingest_events(table, [%{"v" => 1}])
        end

        assert_raise Guardian.Engine.InvalidTableNameError, fn ->
          ingest_events(table, [])
        end

        assert Guardian.Storage.dump_table(table) == []
      end
    end
  end

  defp same_table_reference?(table) do
    case Guardian.AST.parse_statements("SELECT x FROM #{table}") do
      # "schema" parses as an identifier but resolves to the virtual schema table.
      {:ok,
       [
         %Guardian.AST.Node.Statements.SelectStatement{
           from_expr: %Guardian.AST.Node.Identifier{name: ^table},
         },
       ]} ->
        table != "schema"

      _ ->
        false
    end
  end
end

defmodule Guardian.EngineTest do
  use ExUnit.Case, async: true
  import Guardian.Engine
  import Guardian.Test.Segments, only: [intercept_append: 2]

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

    # The returned event is what Storage stores. A field missing from some objects in a
    # list reads back as nil in those objects.
    expected = %{
      "a" => %{"c" => 1},
      "x" => [%{"b" => 2}, %{"b" => 3}],
      "deep" => %{"ok" => true},
      "dotted.key" => %{"q\"uote" => "v"},
      "items" => [%{"id" => 1, "tags" => ["t"]}, %{"id" => 2, "tags" => nil}],
    }

    assert ingest_event(table, event) == expected

    assert Guardian.Storage.dump_table(table)
           |> Enum.map(&Guardian.Storage.Flattening.unflatten_event/1) == [
             expected,
           ]
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
      assert ingest_event(table, event) == event
      assert flat_row in Guardian.Storage.dump_table(table)
    end
  end

  test "drops an invalid value from an array mixing scalars and objects" do
    table = "engine_mixed_invalid_#{System.unique_integer([:positive])}"
    event = %{"x" => [1, %{"a" => 2, "b" => 2 ** 64}], "y" => 1}

    # This shape cannot be rebuilt from its flattened form, so the reported event
    # omits the whole top-level field that lost a value.
    assert ingest_event(table, event) == %{"y" => 1}

    assert Guardian.Storage.dump_table(table) == [%{"x" => [1], "x..a" => [nil, 2], "y" => 1}]
  end

  test "merges nested objects whose keys collide as strings" do
    table = "engine_key_collision_#{System.unique_integer([:positive])}"
    event = %{"x" => %{"b" => 2}, x: %{a: 1}}

    assert ingest_event(table, event) == %{"x" => %{"a" => 1, "b" => 2}}
    assert Guardian.Storage.dump_table(table) == [%{"x.a" => 1, "x.b" => 2}]

    # Colliding lists of objects are merged by flattening, so the reported event is
    # rebuilt from what was stored.
    event = %{"x" => [%{"b" => 2}], x: [%{a: 1}]}
    assert ingest_event(table, event) == %{"x" => [%{"a" => 1, "b" => 2}]}
    assert %{"x..a" => [1], "x..b" => [2]} in Guardian.Storage.dump_table(table)
  end

  test "reports a mixed array faithfully in large events" do
    # Maps with more than 32 keys iterate in hash order, where rebuilding a mixed array
    # may overwrite it silently instead of raising.
    table = "engine_mixed_large_#{System.unique_integer([:positive])}"
    others = Map.new(1..40, fn i -> {"k#{i}", i} end)
    event = Map.merge(others, %{"x" => [1, %{"a" => 2, "b" => 2 ** 64}]})

    assert ingest_event(table, event) == others
  end

  test "stores long strings and lists whole" do
    table = "engine_long_values_#{System.unique_integer([:positive])}"
    string = String.duplicate("z", 100_000)
    list = Enum.to_list(1..70_000)
    event = %{"s" => string, "l" => list, "nested" => %{"s" => string}}

    assert ingest_event(table, event) == event

    assert Guardian.Storage.dump_table(table) == [
             %{"s" => string, "l" => list, "nested.s" => string},
           ]
  end

  test "returns atom keys as strings, as they are stored" do
    table = "engine_atom_keys_#{System.unique_integer([:positive])}"
    expected = %{"user" => %{"name" => "Alice"}, "count" => 1, "xs" => [1, %{"a" => 2}]}

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
    assert ingest_event(table, event) == event
  end

  test "ingests batches" do
    table = "engine_batch_#{System.unique_integer([:positive])}"
    events = [%{"value" => 1}, %{"value" => 2}]

    assert ingest_events(table, events) == Enum.map(events, &{:ok, &1})
    assert Guardian.Storage.dump_table(table) == events
  end

  test "batch outcomes preserve input order and continue after non-object events" do
    table = unique_table()
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

  test "a preparation exception is reported as not stored and the batch continues" do
    table = unique_table()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert ingest_events(table, [
                 %{{:bad, "ingest-log-marker"} => "ingest-log-marker"},
                 %{"value" => 2},
               ]) == [
                 {:error, "internal error before storage; the event was not stored"},
                 {:ok, %{"value" => 2}},
               ]
      end)

    # The kind and the stack trace, never the event's contents (the failing call's
    # argument is the key) or the exception's message.
    assert log =~ "Event ingestion failed for #{table}: FunctionClauseError"
    assert log =~ "lib/"
    refute log =~ "ingest-log-marker"
    refute log =~ "{:bad"
    assert Guardian.Storage.dump_table(table) == [%{"value" => 2}]
  end

  test "a failure with a fun stack frame is redacted and the batch continues" do
    table = unique_table()
    marker = "private-fun-frame-marker"
    key = %Guardian.Test.EngineKey{marker: marker}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # An empty object produces no columns, so the key is stringified only while
        # building the reported event, where the fixture raises with a fun frame.
        assert ingest_events(table, [%{key => %{}}, %{"value" => 2}]) == [
                 {:error, "internal error before storage; the event was not stored"},
                 {:ok, %{"value" => 2}},
               ]
      end)

    assert log =~ "Event ingestion failed for #{table}: RuntimeError"
    assert log =~ "Guardian.Failure.redacted/0"
    refute log =~ marker
    assert Guardian.Storage.dump_table(table) == [%{"value" => 2}]
  end

  test "an explicit segment refusal is reported as not stored and the batch continues" do
    table = unique_table()
    intercept_append(table, fn from, _row -> GenServer.reply(from, {:error, :invalid_value}) end)

    assert ingest_events(table, [%{"value" => 1}, %{"value" => 2}]) == [
             {:error, "value cannot be stored; the event was not stored"},
             {:ok, %{"value" => 2}},
           ]

    assert Guardian.Storage.dump_table(table) == [%{"value" => 2}]

    raising_table = unique_table()

    intercept_append(raising_table, fn from, _row ->
      GenServer.reply(from, {:error, :invalid_value})
    end)

    assert_raise ArgumentError, "value cannot be stored", fn ->
      ingest_event(raising_table, %{"value" => 3})
    end
  end

  test "a segment call exit is reported as uncertain and the batch continues" do
    table = unique_table()
    intercept_append(table, fn _from, _row -> exit(:ingest_test_failure) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert ingest_events(table, [%{"value" => 1}, %{"value" => 2}]) == [
                 {:error, "internal error; the event may have been stored"},
                 {:ok, %{"value" => 2}},
               ]
      end)

    assert log =~ "ingest_test_failure"
    assert Guardian.Storage.dump_table(table) == [%{"value" => 2}]
  end

  test "HTTP reports a timed-out append as uncertain even when the event was stored" do
    table = unique_table()

    intercept_append(table, fn from, row ->
      :ok = Guardian.Storage.append_flattened(table, row)
      Process.sleep(5_200)
      GenServer.reply(from, :ok)
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn =
          Plug.Test.conn(:post, "/api/json/send_events", %{
            "table" => table,
            "events" => [%{"value" => 1}, %{"value" => 2}],
          })
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header(
            "x-api-key",
            Application.fetch_env!(:guardian, :admin_api_key)
          )
          |> Guardian.Web.MainRouter.call(nil)

        assert conn.status == 200

        assert Jason.decode!(conn.resp_body) == %{
                 "status" => 200,
                 "results" => [
                   %{
                     "success" => false,
                     "error" => "internal error; the event may have been stored",
                   },
                   %{"success" => true, "event" => %{"value" => 2}},
                 ],
               }
      end)

    assert log =~ "exit :timeout"
    assert Guardian.Storage.dump_table(table) == [%{"value" => 1}, %{"value" => 2}]
  end

  defp unique_table do
    "engine_outcomes_#{System.unique_integer([:positive])}"
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
        assert [
                 %Guardian.AST.Node.Statements.SelectStatement{
                   from_expr: %Guardian.AST.Node.Identifier{name: ^table},
                 },
               ] =
                 Guardian.AST.parse_statements("SELECT x FROM #{table}")

        assert [
                 %Guardian.AST.Node.Statements.DescStatement{
                   expr: %Guardian.AST.Node.Identifier{name: ^table},
                 },
               ] =
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
      [
        %Guardian.AST.Node.Statements.SelectStatement{
          from_expr: %Guardian.AST.Node.Identifier{name: ^table},
        },
      ] ->
        table != "schema"

      _ ->
        false
    end
  rescue
    Guardian.AST.ParseError -> false
  end
end

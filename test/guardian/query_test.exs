# defmodule QueryTestHelper do
#   defmacro test_query(source, rows, expected_result) do
#         table = "t" <> (:crypto.strong_rand_bytes(8) |> Base.encode16())
#         # IO.inspect(table, label: "table")
#         # source = unquote(source)
#         ast = Guardian.AST.parse(source)
#         source2 = Guardian.AST.unparse(ast)
#         ^ast = Guardian.AST.parse(source2)
#         %SelectStatement{from_expr: nil} = statement = ast
#         ast3 = %SelectStatement{statement | from_expr: %Guardian.AST.Node.Identifier{name: table}}
#         source3 = Guardian.AST.unparse(ast3)
#         # IO.inspect(source3, label: "source3")

#     quote location: :keep do
#       test unquote(source) do
#         # IO.inspect(unquote(rows), label: "rows")
#         rows = Enum.map(unquote(rows), fn row ->
#           Enum.map(row, fn {key, value} -> {to_string(key), value} end)
#         end)
#         # IO.inspect(unquote(table), label: "table")
#         # IO.inspect(rows, label: "rows")
#         # IO.inspect(unquote(source3), label: "source3")
#         :ok = Guardian.Storage.append(unquote(table), rows)
#         assert run(unquote(source3)) == unquote(expected_result)
#       end
#     end
#   end
# end

defmodule Guardian.QueryTest do
  import Guardian.Test.Query, only: [run_sql: 1]
  # import QueryTestHelper
  # require QueryTestHelper
  # Not async: a test refutes "[error]" in captured log output, which sees every process.
  use ExUnit.Case, async: false

  defp run(source) do
    run_sql(source)
  end

  # test_query(
  #   "select v",
  #   [
  #     [k: "foo", v: 1],
  #     [k: "foo", v: 2],
  #     [k: "bar", v: 3]
  #   ],
  #   [[1], [2], [3]]
  # )

  describe "errors while workers evaluate expressions" do
    # test_raise/1 (test build only) raises; any exception during evaluation behaves alike.
    setup do
      table = "worker_errors_#{System.unique_integer([:positive])}"
      for v <- 1..5, do: :ok = Guardian.Storage.append(table, k: rem(v, 2), v: v)
      %{table: table}
    end

    test "fail the query instead of dropping rows", %{table: table} do
      error =
        assert_raise Guardian.Query.Error, fn -> run("select test_raise(v) from #{table}") end

      assert error.message =~ "query evaluation failed"
      assert error.message =~ "test_raise"

      assert_raise Guardian.Query.Error, fn ->
        run("select count() from #{table} where test_raise(v) = 1")
      end

      assert_raise Guardian.Query.Error, fn ->
        run("select k, count() from #{table} where test_raise(v) = 1 group by k")
      end

      assert_raise Guardian.Query.Error, fn ->
        run("select v from #{table} order by test_raise(v)")
      end
    end

    test "do not affect the next query in the same process", %{table: table} do
      assert_raise Guardian.Query.Error, fn -> run("select test_raise(v) from #{table}") end
      assert run("select count() from #{table}") == [[5]]
      assert_raise Guardian.Query.Error, fn -> run("select test_raise(v) from #{table}") end
      assert Enum.sort(run("select v from #{table}")) == [[1], [2], [3], [4], [5]]
    end

    test "leave no messages or linked processes behind", %{table: table} do
      {:links, links_before} = Process.info(self(), :links)
      assert_raise Guardian.Query.Error, fn -> run("select test_raise(v) from #{table}") end
      assert run("select 1") == [[1]]
      assert {:messages, []} = Process.info(self(), :messages)
      assert {:links, ^links_before} = Process.info(self(), :links)
    end
  end

  test "a node that is not an expression fails the query, naming it" do
    table = "not_expressions_#{System.unique_integer([:positive])}"
    :ok = Guardian.Storage.append(table, x: 1)

    assert_raise Guardian.Query.Error, "count() cannot be evaluated as an expression", fn ->
      run("select x from #{table} where count(*) > 1")
    end

    assert_raise Guardian.Query.Error, "* cannot be evaluated as an expression", fn ->
      run("select x from #{table} where * = 1")
    end

    assert_raise Guardian.Query.Error, "x ASC cannot be evaluated as an expression", fn ->
      run("select abs(x asc) from #{table}")
    end
  end

  test "an aggregate's Guardian.Query.Error reaches the caller with its message" do
    table = "top_n_errors_#{System.unique_integer([:positive])}"
    for v <- 1..5, do: :ok = Guardian.Storage.append(table, k: rem(v, 2), v: v)

    # Guarded like evaluation: no worker crash report reaches the log.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert_raise Guardian.Query.Error,
                     "min_n: n must be the same for every row of a group",
                     fn ->
                       run("select min_n(v, k + 1) from #{table}")
                     end

        assert_raise Guardian.Query.Error, "max_n: n must be a non-negative integer", fn ->
          run("select max_n(v, -1) from #{table}")
        end

        # A crashed worker's report is logged after the query has already failed.
        Process.sleep(200)
      end)

    refute log =~ "[error]"

    # n may differ between groups.
    assert run("select k, min_n(v, k + 1) from #{table} group by k order by k") ==
             [[0, [2]], [1, [1, 3]]]

    # Aggregates of arity 3, 0 and 1 in one row split it by arity.
    assert run("select k, min_n_by(v, v, 2), count(), max(v) from #{table} group by k order by k") ==
             [[0, [2, 4], 2, 4], [1, [1, 3], 3, 5]]
  end

  test "run" do
    :ok = Guardian.Storage.append("t", k: "foo", v: 1)
    :ok = Guardian.Storage.append("t", k: "foo", v: 2)
    :ok = Guardian.Storage.append("t", k: "bar", v: 3)

    assert run("select v from t") == [[1], [2], [3]]
    assert run("select x, v from t") == [[nil, 1], [nil, 2], [nil, 3]]
    assert run("select x from t") == [[nil], [nil], [nil]]
    assert run("select k, avg(v) group by k order by k from t") == [["bar", 3], ["foo", 1.5]]
    assert run("select k, avg(v) group by k order by avg(v) from t") == [["foo", 1.5], ["bar", 3]]

    assert run("select v order by v from t") == [[1], [2], [3]]
    assert run("select v order by v limit 3 from t") == [[1], [2], [3]]
    assert run("select v order by v limit 2 from t") == [[1], [2]]
    assert run("select v order by v limit 1 from t") == [[1]]
    assert run("select v order by v limit 0 from t") == []

    assert run("select v order by -v from t") == [[3], [2], [1]]
    assert run("select v order by -v limit 2 from t") == [[3], [2]]

    assert run("select v from t") == [[1], [2], [3]]
    assert run("select v from t order by v asc") == [[1], [2], [3]]
    assert run("select v from t order by v desc") == [[3], [2], [1]]

    assert run("select v from t order by k asc, v asc") == [[3], [1], [2]]
    assert run("select v from t order by k asc, v desc") == [[3], [2], [1]]
    assert run("select v from t order by k desc, v asc") == [[1], [2], [3]]
    assert run("select v from t order by k desc, v desc") == [[2], [1], [3]]

    assert run("select * from t") == [["foo", 1], ["foo", 2], ["bar", 3]]

    assert run("select k, min(v), max(v) group by k order by k from t") == [
             ["bar", 3, 3],
             ["foo", 1, 2],
           ]

    assert run("select min(v), max(v) from t") == [[1, 3]]
    assert run("select min_by(k, v) from t") == [["foo"]]
    assert run("select max_by(k, v) from t") == [["bar"]]

    assert run("select count() from t2") == [[0]]

    assert run("select count() from t") == [[3]]
    assert run("select count(1) from t") == [[3]]
    assert run("select count(k) from t") == [[3]]
    assert run("select count(x) from t") == [[0]]

    assert run("select count_distinct(k) from t") == [[2]]
    assert run("select count_distinct(v) from t") == [[3]]

    assert run("select count_if(true) from t") == [[3]]
    assert run("select count_if(false) from t") == [[0]]
    assert run("select count_if(nil) from t") == [[0]]

    assert run("select count_if(v > 0) from t") == [[3]]
    assert run("select count_if(v > 1) from t") == [[2]]
    assert run("select count_if(v > 2) from t") == [[1]]
    assert run("select count_if(v > 3) from t") == [[0]]
    assert run("select count_if(v > 4) from t") == [[0]]

    assert run("select count_if(v >= 0) from t") == [[3]]
    assert run("select count_if(v >= 1) from t") == [[3]]
    assert run("select count_if(v >= 2) from t") == [[2]]
    assert run("select count_if(v >= 3) from t") == [[1]]
    assert run("select count_if(v >= 4) from t") == [[0]]

    assert run("select count_if(v < 0) from t") == [[0]]
    assert run("select count_if(v < 1) from t") == [[0]]
    assert run("select count_if(v < 2) from t") == [[1]]
    assert run("select count_if(v < 3) from t") == [[2]]
    assert run("select count_if(v < 4) from t") == [[3]]

    assert run("select count_if(v <= 0) from t") == [[0]]
    assert run("select count_if(v <= 1) from t") == [[1]]
    assert run("select count_if(v <= 2) from t") == [[2]]
    assert run("select count_if(v <= 3) from t") == [[3]]
    assert run("select count_if(v <= 4) from t") == [[3]]
  end

  test "dotted field paths address nested columns" do
    table = "nested_paths_test"

    :ok =
      Guardian.Storage.append(table, %{
        "user" => %{"name" => "Bob", "address" => %{"city" => "NYC"}},
      })

    :ok = Guardian.Storage.append(table, %{"user" => %{"name" => "Alice"}, "n" => 1})
    :ok = Guardian.Storage.append(table, %{"user" => %{"name" => "Bob"}, "n" => 2})
    :ok = Guardian.Storage.append(table, %{"users" => [%{"name" => "Joe"}, %{"name" => "Ann"}]})
    :ok = Guardian.Storage.append(table, %{"grid" => [[%{"x" => 1}, %{"x" => 2}], [%{"x" => 3}]]})

    assert run("select user.name from #{table}") == [["Bob"], ["Alice"], ["Bob"], [nil], [nil]]
    assert run("select n from #{table} where user.name = 'Bob'") == [[nil], [2]]

    assert run("select user.address.city from #{table} where user.address.city is not null") ==
             [["NYC"]]

    assert run(
             "select user.name, count(*), sum(n) from #{table} " <>
               "where user.name is not null group by user.name order by user.name"
           ) == [["Alice", 1, 1], ["Bob", 2, 2]]

    assert run("select upper(user.name) from #{table} where n = 1") == [["ALICE"]]

    assert run("select users..name from #{table}") ==
             [[nil], [nil], [nil], [["Joe", "Ann"]], [nil]]

    assert run("select grid...x from #{table}") == [[nil], [nil], [nil], [nil], [[[1, 2], [3]]]]

    assert labels("select user.name, users..name from #{table}") == ["user.name", "users..name"]

    # Names from SELECT * can be pasted back into a query.
    [{statement, star_labels}] = Guardian.Query.Resolver.resolve("select * from #{table}")
    assert "user.address.city" in star_labels
    assert "users..name" in star_labels
    assert "grid...x" in star_labels

    assert run("select #{Enum.join(star_labels, ", ")} from #{table}") ==
             Guardian.Query.run(statement)
  end

  test "column names match stored names exactly" do
    table = "case_sensitive_test"

    :ok =
      Guardian.Storage.append(table, %{
        "userId" => 1,
        "user" => %{"firstName" => "Bob"},
        "n" => 10,
      })

    :ok =
      Guardian.Storage.append(table, %{
        "userId" => 2,
        "user" => %{"firstName" => "Ann"},
        "n" => 20,
      })

    :ok =
      Guardian.Storage.append(table, %{
        "userId" => 2,
        "user" => %{"firstName" => "Ann"},
        "n" => 30,
      })

    assert run("select userId from #{table}") == [[1], [2], [2]]
    assert run("select userid from #{table}") == [[nil], [nil], [nil]]
    assert run("select userId from #{table} where user.firstname = 'Bob'") == []
    assert run("select userId from #{table} where user.firstName = 'Bob'") == [[1]]

    assert run(
             "select user.firstName, count(*), sum(n) from #{table} " <>
               "group by user.firstName order by userId"
           ) == [["Bob", 1, 10], ["Ann", 2, 50]]

    assert [{_statement, ["userId", "USERID", "upper(user.firstName)", "x"]}] =
             Guardian.Query.Resolver.resolve(
               "select userId, USERID, upper(user.firstName), n as x from #{table}"
             )
  end

  test "two spellings are two columns" do
    table = "case_two_spellings_test"
    :ok = Guardian.Storage.append(table, %{"userId" => 1, "userid" => 2, "n" => 3})

    assert run("select userId, userid from #{table}") == [[1, 2]]

    assert [{statement, ["n", "userId", "userid"]}] =
             Guardian.Query.Resolver.resolve("select * from #{table}")

    assert Guardian.Query.run(statement) == [[3, 1, 2]]
  end

  test "aliases and LET names match exactly and keep their case" do
    table = "case_alias_test"
    :ok = Guardian.Storage.append(table, %{"n" => 1})
    :ok = Guardian.Storage.append(table, %{"n" => 2})

    assert [{_statement, ["Total"]}] =
             Guardian.Query.Resolver.resolve("select n as Total from #{table}")

    assert run("select n as Total from #{table} order by Total desc") == [[2], [1]]
    assert run("let Big = n > 1; select n from #{table} where Big") == [[2]]
    assert run("let Big = n > 1; select n from #{table} where big") == []
  end

  test "keywords and function names match in any case; table names do not" do
    table = "case_words_test"
    :ok = Guardian.Storage.append(table, %{"n" => 1})

    assert run("SeLeCt CoUnT(*), Sum(n), LOWER('A') FrOm #{table}") == [[1, 1, "a"]]
    assert run("select count() from CASE_WORDS_TEST") == [[0]]
    assert run("select Count from #{table}") == [[nil]]
    assert labels("select CoUnT(*), LOWER('A')") == ["count()", "lower('A')"]
    assert run("select CURRENT_DATE = current_date") == [[true]]
    assert run("select TRUE, False, NULL") == [[true, false, nil]]
  end

  test "LET and labels" do
    table = "case_let_test"
    :ok = Guardian.Storage.append(table, %{"total" => 5, "n" => 1})

    assert [{statement, ["total", "n"]}] =
             Guardian.Query.Resolver.resolve(
               "let total = n + 1; select total, total as n from #{table}"
             )

    assert Guardian.Query.run(statement) == [[2, 2]]

    # A LET after the SELECT does not bind names in it.
    assert [{_statement, ["total"]}, {_, _}] =
             Guardian.Query.Resolver.resolve(
               "select total from #{table}; let total = 1; select 2"
             )

    # An alias nested in an expression is not a column.
    assert run("select (total as alias) from #{table}") == [[5]]

    # LET can name the table.
    assert [{statement, ["total"]}] =
             Guardian.Query.Resolver.resolve("let t = #{table}; select total from t")

    assert Guardian.Query.run(statement) == [[5]]
  end

  test "the smallest int64 is written as an expression" do
    assert run("select -9223372036854775807 - 1") == [[-9_223_372_036_854_775_808]]
    assert run("select 9223372036854775807") == [[9_223_372_036_854_775_807]]

    assert_raise Guardian.AST.ParseError, ~r/Number out of range/, fn ->
      run("select -9223372036854775808")
    end
  end

  # A statement's column labels as the query interfaces return them.
  defp labels(sql) do
    [{_statement, labels}] = Guardian.Query.Resolver.resolve(sql)
    labels
  end

  test "labels" do
    assert labels("select foo, bar") == ["foo", "bar"]
    assert labels("select foo as bar") == ["bar"]
    assert labels("select foo as 'bar'") == ["bar"]
    assert labels("show tables") == ["table"]
    assert labels("desc foo") == ["key"]
  end

  test "show tables" do
    :ok = Guardian.Storage.append("show_tables_test", x: 1)

    tables = run("show tables") |> Enum.map(&hd/1)
    assert "show_tables_test" in tables
  end

  test "desc" do
    :ok = Guardian.Storage.append("desc_test", name: "alice", score: 100)

    keys = run("desc desc_test") |> Enum.map(&hd/1)
    assert "name" in keys
    assert "score" in keys
  end

  test "comparing with a number literal skips non-numbers when every number is on one side" do
    table = "comparison_fast_path_test_#{System.unique_integer([:positive])}"

    for x <- [10, 2.5, nil, "s", true, [3]] do
      :ok = Guardian.Storage.append(table, %{"k" => inspect(x), "x" => x})
    end

    :ok = Guardian.Storage.append(table, %{"k" => "missing"})

    assert Enum.sort(run("select k from #{table} where x > 0")) == [["10"], ["2.5"]]
    assert Enum.sort(run("select k from #{table} where 0 <= x")) == [["10"], ["2.5"]]
    assert Enum.sort(run("select k from #{table} where x > 2")) == [["10"], ["2.5"]]
    assert run("select k from #{table} where x > 20") == []
    assert Enum.sort(run("select k from #{table} where x between 0 and 100")) == [["10"], ["2.5"]]
    assert run("select k from #{table} where not (x > 20)") |> Enum.sort() == [["10"], ["2.5"]]

    assert Enum.sort(run("select k, x > 20 from #{table}")) ==
             Enum.sort([
               ["10", false],
               ["2.5", false],
               ["nil", nil],
               [~s("s"), nil],
               ["true", nil],
               ["[3]", nil],
               ["missing", nil],
             ])
  end

  test "WHERE keeping only some rows of a segment with list values" do
    table = "list_filter_test_#{System.unique_integer([:positive])}"

    for row <- [
          %{"a" => 1},
          %{"tags" => ["x", "y"]},
          %{"tags" => ["only"]},
          %{"tags" => [["n"], [1, "m"]]},
          %{"tags" => 7},
          %{"a" => 2, "tags" => nil},
        ] do
      :ok = Guardian.Storage.append(table, row)
    end

    assert_queries = fn ->
      assert Enum.sort(run("select tags from #{table} where tags is not null")) ==
               Enum.sort([[["x", "y"]], [["only"]], [[["n"], [1, "m"]]], [7]])

      assert run("select tags from #{table} where tags is null") |> length() == 2
      assert run("select a from #{table} where tags is not null") |> length() == 4

      assert Enum.sort(run("select a, tags from #{table} where a is not null")) ==
               [[1, nil], [2, nil]]
    end

    # Mutable segments.
    assert_queries.()

    # Full, then persisted and loaded from disk.
    for segment <- Guardian.Storage.MutableSegments.get_mutable_segments(table) do
      :ok = Guardian.Storage.MutableSegments.segment_is_full(table, segment)
    end

    :sys.get_state(Guardian.Storage.PersistedSegments)
    :ok = Guardian.Storage.LoadedSegments.rescan()
    assert Guardian.Storage.LoadedSegments.segment_ids(table) != []
    assert Guardian.Storage.MutableSegments.segment_ids(table) == []
    assert_queries.()
  end

  test "WHERE on list-of-object paths keeping only some rows" do
    table = "list_path_filter_test_#{System.unique_integer([:positive])}"

    for row <- [
          %{"a" => 1},
          %{"users" => [%{"name" => "Joe"}, %{"name" => "Ann"}]},
          %{"users" => [%{"age" => 3}]},
          %{"users" => [%{"name" => "Sue", "age" => 4}, %{"age" => 5}]},
          %{"grid" => [[%{"x" => 1}, %{"x" => 2}], [%{"x" => 3}]]},
        ] do
      :ok = Guardian.Storage.append(table, row)
    end

    # Flattening drops trailing nils from list columns: Sue's list loses the missing
    # name, and the row whose only object has no name stores no users..name at all.
    assert run("select users..name from #{table} where users..name is not null") ==
             [[["Joe", "Ann"]], [["Sue"]]]

    assert run("select users..age from #{table} where users..name is not null") ==
             [[nil], [[4, 5]]]

    assert run("select grid...x from #{table} where grid...x is not null") == [[[[1, 2], [3]]]]
  end

  describe "reassembling rows into columns" do
    test "rows become one column per key" do
      assert [a, b] =
               Guardian.Query.Executor.rows_to_columns([[1, ["x"]], [2, ["y"]]], ["a", "b"])

      assert Guardian.Storage.Column.to_list(a) === [1, 2]
      assert Guardian.Storage.Column.to_list(b) === [["x"], ["y"]]
    end

    test "list-heavy rows stay in order" do
      big = List.duplicate(1, 40_000)
      rows = [[1, big], [2, big], [3, [7]], [4, big]]

      assert [n, l] = Guardian.Query.Executor.rows_to_columns(rows, ["n", "l"])
      assert Guardian.Storage.Column.to_list(n) == [1, 2, 3, 4]
      assert Guardian.Storage.Column.to_list(l) == [big, big, [7], big]
    end

    test "a value no column can hold raises naming the column" do
      assert_raise ArgumentError, ~r/query result column "l"/, fn ->
        Guardian.Query.Executor.rows_to_columns([[1, [1]], [2, [[[1]]]]], ["n", "l"])
      end
    end
  end

  describe "execute" do
    test "runs one statement, labeled before LET" do
      table = "execute_test_#{System.unique_integer([:positive])}"
      :ok = Guardian.Storage.append(table, %{"N" => 1})

      assert Guardian.Query.execute("let x = N + 1; select x, N from #{table}") ==
               {:ok, ["x", "N"], [[2, 1]]}
    end

    test "requires exactly one statement" do
      assert Guardian.Query.execute("") == {:error, "Query resolved to no executable statements"}

      assert Guardian.Query.execute("let x = 1") ==
               {:error, "Query resolved to no executable statements"}

      assert Guardian.Query.execute("select 1; select 2") ==
               {:error, "Only single-statement queries are supported"}
    end

    test "hands a parse error to on_parse_error, then reraises it" do
      parent = self()
      on_parse_error = fn error -> send(parent, {:parse_error, error}) end

      error =
        assert_raise Guardian.AST.ParseError, fn ->
          Guardian.Query.execute("select from", on_parse_error: on_parse_error)
        end

      assert_received {:parse_error, ^error}
      refute_received {:parse_error, _}
    end

    test "returns a Guardian.Query.Error from running the query" do
      assert {:error, "max_n: n must be a non-negative integer"} =
               Guardian.Query.execute("select max_n(1, -1)")
    end

    test "labels each column of a LET name standing for *" do
      table = "execute_star_test_#{System.unique_integer([:positive])}"
      :ok = Guardian.Storage.append(table, %{"a" => 1, "b" => 2})

      assert Guardian.Query.execute("let x = *; select x from #{table}") ==
               {:ok, ["a", "b"], [[1, 2]]}

      assert Guardian.Query.execute("let x = *; select b as first, x from #{table}") ==
               {:ok, ["first", "a", "b"], [[2, 1, 2]]}

      assert Guardian.Query.execute("select *, a from #{table}") ==
               {:ok, ["a", "b", "a"], [[1, 2, 1]]}

      assert Guardian.Query.execute("let coalesce(q) = *; select coalesce(1) from #{table}") ==
               {:ok, ["a", "b"], [[1, 2]]}

      assert Guardian.Query.execute("let t = #{table}; let x = *; select x from t") ==
               {:ok, ["a", "b"], [[1, 2]]}
    end

    test "FROM _stream is an ordinary table name" do
      assert Guardian.Query.execute("select v from _stream") == {:ok, ["v"], []}
    end

    test "returns a Guardian.Query.Error from resolving the query, without on_parse_error" do
      on_parse_error = fn error -> flunk("unexpected #{inspect(error)}") end
      star = "SELECT * needs FROM and a table name"
      from = "FROM needs a table name"
      desc = "DESC needs a table name"
      let_arity = ~s(Wrong number of arguments to LET function "coalesce")

      for {sql, message} <- [
            {"select *", star},
            {"let x = *; select x", star},
            {"select * from 1", from},
            {"select v from 1", from},
            {"select v from '_stream'", from},
            {"select v from (t)", from},
            {"let t = 1; select v from t", from},
            {"let t = '_stream'; select v from t", from},
            {"desc 1", desc},
            {"desc 'x'", desc},
            {"let coalesce(a) = a; select coalesce(1, 2)", let_arity},
          ] do
        assert Guardian.Query.execute(sql, on_parse_error: on_parse_error) == {:error, message},
               sql
      end
    end
  end
end

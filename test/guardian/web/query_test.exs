defmodule Guardian.Web.QueryTest do
  # The MCP query tool's runner, called directly. Its MCP-level behavior is in
  # Guardian.Web.MCP.ClientTest. What it records in the built-in tables is not tested
  # (CONTRIBUTING.md, "Testing philosophy").
  use ExUnit.Case, async: true
  import Guardian.Web.Query

  defp run(sql) do
    execute(sql, fn -> %{"interface" => "mcp"} end)
  end

  test "runs a grouped query and returns labels and rows" do
    table = "web_query_#{System.unique_integer([:positive])}"
    Guardian.Engine.ingest_event(table, %{"ip" => "1.2.3.4", "status" => 404})
    Guardian.Engine.ingest_event(table, %{"ip" => "1.2.3.4", "status" => 404})
    Guardian.Engine.ingest_event(table, %{"ip" => "5.6.7.8", "status" => 404})

    assert run(
             "SELECT ip, count() FROM #{table} WHERE status = 404 GROUP BY ip ORDER BY count() DESC"
           ) == {:ok, ["ip", "count()"], [["1.2.3.4", 2], ["5.6.7.8", 1]]}
  end

  test "answers a Guardian.Query.Error with its message" do
    table = "web_query_error_#{System.unique_integer([:positive])}"
    Guardian.Engine.ingest_event(table, %{"v" => 1})

    assert {:error, info} = run("SELECT test_raise(v) FROM #{table}")
    assert info =~ "query evaluation failed"
  end

  test "resolves SELECT *, SHOW TABLES, DESC, and LET, and requires one statement" do
    table = "web_query_resolve_#{System.unique_integer([:positive])}"
    Guardian.Engine.ingest_event(table, %{"a" => 1, "b" => "x"})

    assert run("SELECT * FROM #{table}") == {:ok, ["a", "b"], [[1, "x"]]}
    assert {:ok, ["table"], tables} = run("SHOW TABLES")
    assert [table] in tables
    assert run("DESC #{table}") == {:ok, ["key"], [["a"], ["b"]]}
    assert run("LET n = a + 1; SELECT n FROM #{table}") == {:ok, ["n"], [[2]]}
    assert run("SELECT 1;") == {:ok, ["1"], [[1]]}
    assert run("SELECT 1; SELECT 2") == {:error, "Only single-statement queries are supported"}
    assert run("LET n = 1") == {:error, "Query resolved to no executable statements"}
    assert run("") == {:error, "Query resolved to no executable statements"}
  end

  test "matches column names exactly" do
    table = "web_query_case_#{System.unique_integer([:positive])}"
    Guardian.Engine.ingest_event(table, %{"userId" => 7, "user" => %{"firstName" => "Bob"}})

    assert run("SELECT userId, user.firstName FROM #{table}") ==
             {:ok, ["userId", "user.firstName"], [[7, "Bob"]]}

    assert run("SELECT USERID, user.firstname FROM #{table}") ==
             {:ok, ["USERID", "user.firstname"], [[nil, nil]]}
  end

  test "answers a parse error with its message" do
    assert {:error, "Parse error on line 1" <> _} = run("SELECT FROM")
  end

  test "failures from the query path reach the caller unchanged" do
    stacktrace = [{SomeModule, :some_function, 2, [file: ~c"sentinel.ex", line: 7]}]

    for {kind, reason} <- [
          {:error, %RuntimeError{message: "internal failure"}},
          {:exit, {:timeout, {GenServer, :call, ["x"]}}},
          {:throw, {:thrown, 1}},
          {:error, :badarg},
        ] do
      Guardian.Test.Web.QueryBackend.fail_next(kind, reason, stacktrace)

      assert {^kind, ^reason, ^stacktrace} =
               (try do
                  run("SELECT 1")
                catch
                  caught_kind, caught_reason -> {caught_kind, caught_reason, __STACKTRACE__}
                end)
    end
  end
end

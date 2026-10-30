defmodule Guardian.Web.QueryTest do
  # The MCP query tool's runner, called directly. Its MCP-level behavior is in
  # Guardian.Web.MCP.ClientTest; recording is in QueryLogTest and QueryParseErrorsTest.
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

  test "matches column names ignoring case" do
    table = "web_query_case_#{System.unique_integer([:positive])}"
    Guardian.Engine.ingest_event(table, %{"userId" => 7, "user" => %{"firstName" => "Bob"}})

    assert run("SELECT USERID, user.firstname FROM #{table}") ==
             {:ok, ["userId", "user.firstName"], [[7, "Bob"]]}
  end

  test "reraises a parse error unchanged" do
    assert_raise Guardian.AST.ParseError, fn -> run("SELECT FROM") end
  end
end

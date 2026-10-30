defmodule Guardian.Query.ResolverTest do
  import Guardian.Query.Resolver
  use ExUnit.Case, async: true

  test "resolve_aliases" do
    assert resolve_aliases("SELECT 1 + 2 AS y GROUP BY y") == "SELECT 1 + 2 AS y GROUP BY 1 + 2"
    assert resolve_aliases("SELECT 1 + 2 AS y HAVING y") == "SELECT 1 + 2 AS y HAVING 1 + 2"
    assert resolve_aliases("SELECT 1 + 2 AS y ORDER BY y") == "SELECT 1 + 2 AS y ORDER BY 1 + 2"
  end

  test "unresolve_statement_index" do
    query = """
    LET x = 1;
    LET y = 2;
    SELECT x + y;
    SELECT x * y;
    """

    assert unresolve_statement_index(query, 0) == 2
    assert unresolve_statement_index(query, 1) == 3
  end

  test "a * that LET substitutes is expanded" do
    keys = Guardian.Query.VirtualTable.Schema.keys()
    assert [{statement, labels}] = resolve("LET x = *; SELECT x FROM schema")
    assert statement.select_exprs == Enum.map(keys, &%Guardian.AST.Node.Identifier{name: &1})
    assert labels == keys
  end

  test "each statement labels a substituted * with its table's columns" do
    keys = Guardian.Query.VirtualTable.Schema.keys()
    sql = "SELECT 1 AS a; LET x = *; ; SELECT x FROM schema; LET y = 2; SELECT y, x FROM schema"

    assert [{_, ["a"]}, {_, ^keys}, {_, labels}] = resolve(sql)
    assert labels == ["y" | keys]
  end
end

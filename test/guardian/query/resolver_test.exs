defmodule Guardian.Query.ResolverTest do
  import Guardian.Query.Resolver
  use ExUnit.Case, async: true

  test "a SELECT alias in GROUP BY, HAVING or ORDER BY stands for its expression" do
    for clause <- ["GROUP BY", "HAVING", "ORDER BY"] do
      assert [{statement, ["y"]}] = resolve("SELECT 1 + 2 AS y #{clause} y")
      assert Guardian.AST.unparse(statement) == "SELECT 1 + 2 AS y #{clause} 1 + 2"
    end
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

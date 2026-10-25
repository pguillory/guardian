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
end

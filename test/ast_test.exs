defmodule ASTTest do
  import AST
  alias AST.Parser
  use ExUnit.Case, async: true

  test "prewalk modifies AST" do
    expr = Parser.parse("1 + 2")

    modified_expr =
      prewalk(expr, fn
        %AST.Node.Literal{value: value} when is_integer(value) ->
          %AST.Node.Literal{value: value * 10}

        expr ->
          expr
      end)

    assert modified_expr |> unparse() == "10 + 20"
  end

  test "prewalk order" do
    expr = Parser.parse("1 + 2")

    {_, prewalk_order} = prewalk(expr, [], fn expr, acc -> {expr, acc ++ [expr]} end)

    assert prewalk_order |> Enum.map(&unparse/1) == ["1 + 2", "1", "2"]
  end

  test "postwalk order" do
    expr = Parser.parse("1 + 2")

    {_, postwalk_order} = postwalk(expr, [], fn expr, acc -> {expr, acc ++ [expr]} end)

    assert postwalk_order |> Enum.map(&unparse/1) == ["1", "2", "1 + 2"]
  end

  # Visit order is load-bearing: walks collect in it (the planner numbers HAVING's
  # aggregate columns that way), and the Resolver parks AS nodes in a pre step and
  # restores them in the post step. Pin it for a representative node of each shape.
  test "traversal visits children in field order, pre before and post after" do
    walk = fn source ->
      expr =
        case Parser.parse(source) do
          [statement] -> statement
          expr -> expr
        end

      {_, pre} = prewalk(expr, [], fn expr, acc -> {expr, acc ++ [unparse(expr)]} end)
      {_, post} = postwalk(expr, [], fn expr, acc -> {expr, acc ++ [unparse(expr)]} end)
      {pre, post}
    end

    select =
      "SELECT a, concat(b, c) AS d FROM t WHERE x > 1 GROUP BY a HAVING count(*) > 2 " <>
        "ORDER BY a DESC LIMIT 5"

    unparsed = String.replace(select, "count(*)", "count()")

    assert walk.(select) ==
             {[unparsed] ++
                ~w[a] ++
                ["concat(b, c) AS d", "concat(b, c)"] ++
                ~w[b c d t] ++
                ["x > 1", "x", "1", "a", "count() > 2", "count()", "2", "a DESC", "a", "5"],
              ~w[a b c] ++
                ["concat(b, c)", "d", "concat(b, c) AS d", "t", "x", "1", "x > 1", "a"] ++
                ["count()", "2", "count() > 2", "a", "a DESC", "5", unparsed]}

    assert walk.("CASE WHEN a THEN b ELSE c END") ==
             {["CASE WHEN a THEN b ELSE c END", "a", "b", "c"],
              ["a", "b", "c", "CASE WHEN a THEN b ELSE c END"]}

    assert walk.("CASE a WHEN 1 THEN b END") ==
             {["CASE a WHEN 1 THEN b END", "a", "1", "b"],
              ["a", "1", "b", "CASE a WHEN 1 THEN b END"]}

    assert walk.("x BETWEEN 1 AND 2") ==
             {["x BETWEEN 1 AND 2", "x", "1", "2"], ["x", "1", "2", "x BETWEEN 1 AND 2"]}

    assert walk.("x IN [1, y]") ==
             {["x IN [1, y]", "x", "[1, y]", "1", "y"], ["x", "1", "y", "[1, y]", "x IN [1, y]"]}

    # All WHENs come before all THENs: fields are walked one at a time.
    assert walk.("CASE WHEN a THEN b WHEN c THEN d END") ==
             {["CASE WHEN a THEN b WHEN c THEN d END", "a", "c", "b", "d"],
              ["a", "c", "b", "d", "CASE WHEN a THEN b WHEN c THEN d END"]}

    assert walk.("SELECT sum(x) FROM t ORDER BY a ASC, b") ==
             {["SELECT sum(x) FROM t ORDER BY a ASC, b", "sum(x)", "x", "t", "a ASC", "a", "b"],
              ["x", "sum(x)", "t", "a", "a ASC", "b", "SELECT sum(x) FROM t ORDER BY a ASC, b"]}

    assert walk.("(a + b) * c") ==
             {["(a + b) * c", "(a + b)", "a + b", "a", "b", "c"],
              ["a", "b", "a + b", "(a + b)", "c", "(a + b) * c"]}

    assert walk.("NOT -x") == {["NOT - x", "- x", "x"], ["x", "- x", "NOT - x"]}
    assert walk.("LET a = 1") == {["LET a = 1", "a", "1"], ["a", "1", "LET a = 1"]}
    assert walk.("DESC t") == {["DESC t", "t"], ["t", "DESC t"]}
  end

  test "valid_identifier" do
    assert valid_identifier("foo") == true
    assert valid_identifier("1 + 2") == false
    assert valid_identifier("1 +") == false
  end
end

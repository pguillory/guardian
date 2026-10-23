defmodule Query.PlannerTest do
  import Query.Planner
  use ExUnit.Case, async: true

  alias AST.Node.Statements.SelectStatement

  def debug_query_plan(source) do
    [%SelectStatement{}] = [statement] = AST.parse(source)

    query_plan(statement)
    |> Enum.map(fn
      {:select, select_exprs} ->
        select_exprs = Enum.map(select_exprs, &AST.unparse/1)
        {:select, select_exprs}

      {:from, nil} ->
        {:from, nil}

      {:from, from_expr} ->
        from_expr = AST.unparse(from_expr)
        {:from, from_expr}

      {:where, where_expr} ->
        where_expr = AST.unparse(where_expr)
        {:where, where_expr}

      {:select_where, select_exprs, where_expr} ->
        select_exprs = Enum.map(select_exprs, &AST.unparse/1)
        where_expr = AST.unparse(where_expr)
        {:select_where, select_exprs, where_expr}

      {:group_by, group_by_exprs, aggregate_names_and_arities} ->
        group_by_exprs = Enum.map(group_by_exprs, &AST.unparse/1)

        aggregate_names_and_arities =
          Enum.map(aggregate_names_and_arities, fn {name, arity} ->
            {String.to_atom(name), arity}
          end)

        {:group_by, group_by_exprs, aggregate_names_and_arities}

      {:default, default_row} ->
        {:default, default_row}

      {:reassemble_segments, keys_and_old_exprs} ->
        keys_and_old_exprs =
          Enum.map(keys_and_old_exprs, fn {key, old_expr} ->
            {String.to_atom(key), AST.unparse(old_expr)}
          end)

        {:reassemble_segments, keys_and_old_exprs}

      {:order_by, _directions} = step ->
        step

      {:limit, _limit} = step ->
        step

      {:order_by_limit, _directions, _limit} = step ->
        step
    end)
  end

  test "query_plan" do
    assert debug_query_plan("select a, b") == [
             {:from, nil},
             {:select, ["a", "b"]},
           ]

    assert debug_query_plan("select a, b where c") == [
             {:from, nil},
             {:select_where, ["a", "b"], "c"},
           ]

    assert debug_query_plan("select a, b where c group by d, e") == [
             {:from, nil},
             {:select_where, ["d", "e", "a", "b"], "c"},
             {:group_by, ["d", "e"], [arbitrary: 1, arbitrary: 1]},
           ]

    assert debug_query_plan("select a, b where c group by d, e order by f, g limit 10") == [
             {:from, nil},
             {:select_where, ["d", "e", "f", "g", "a", "b"], "c"},
             {:group_by, ["d", "e"], [arbitrary: 1, arbitrary: 1, arbitrary: 1, arbitrary: 1]},
             {:order_by_limit, [:asc, :asc], 10},
           ]

    assert debug_query_plan("select a, avg(b) group by c") == [
             {:from, nil},
             {:select, ["c", "a", "b"]},
             {:group_by, ["c"], [arbitrary: 1, avg: 1]},
           ]

    assert debug_query_plan(
             "select a, avg(b) where w > 5 group by c having avg(b) > 5 order by e"
           ) == [
             {:from, nil},
             {:select_where, ["c", "b", "e", "a"], "w > 5"},
             {:group_by, ["c"], [avg: 1, arbitrary: 1, arbitrary: 1]},
             {:reassemble_segments, [v0: "avg(b)", v1: "e", v2: "a"]},
             {:select_where, ["v1", "v2", "v0"], "v0 > 5"},
             {:order_by, [:asc]},
           ]

    # The sort expressions are selected first, in ORDER BY order; each step carries
    # only their directions.
    assert debug_query_plan("select a from t order by b desc, c, d asc") == [
             {:from, "t"},
             {:select, ["b", "c", "d", "a"]},
             {:order_by, [:desc, :asc, :asc]},
           ]

    assert debug_query_plan("select a from t order by b, c desc limit 5") == [
             {:from, "t"},
             {:select, ["b", "c", "a"]},
             {:order_by_limit, [:asc, :desc], 5},
           ]

    assert debug_query_plan("select a from t limit 0") == [
             {:from, "t"},
             {:select, ["a"]},
             {:limit, 0},
           ]

    assert debug_query_plan("select a, avg(b)") == [
             {:from, nil},
             {:select, ["null", "a", "b"]},
             {:group_by, ["null"], [arbitrary: 1, avg: 1]},
             {:default, [nil, nil]},
           ]

    assert debug_query_plan("select a, count()") == [
             {:from, nil},
             {:select, ["null", "a"]},
             {:group_by, ["null"], [arbitrary: 1, count: 0]},
             {:default, [nil, 0]},
           ]

    assert debug_query_plan("select min(a), var_pop(b), count()") == [
             {:from, nil},
             {:select, ["null", "a", "b"]},
             {:group_by, ["null"], [min: 1, var_pop: 1, count: 0]},
             {:default, [nil, nil, 0]},
           ]

    assert debug_query_plan("select a, count() group by b") == [
             {:from, nil},
             {:select, ["b", "a"]},
             {:group_by, ["b"], [arbitrary: 1, count: 0]},
           ]

    assert debug_query_plan("select a, round(avg(b))") == [
             {:from, nil},
             {:select, ["null", "a", "b"]},
             {:group_by, ["null"], [arbitrary: 1, avg: 1]},
             {:default, [nil, nil]},
             {:reassemble_segments, [v0: "a", v1: "avg(b)"]},
             {:select_where, ["v0", "round(v1)"], "true"},
           ]
  end

  # The parser accepts only an integer literal after LIMIT; a statement built some
  # other way fails planning with an ArgumentError that says why.
  test "a LIMIT that is not a non-negative integer literal fails planning" do
    [statement] = AST.parse("select a from t limit 1")

    message = ~r/^LIMIT must be a non-negative integer literal, got: /

    for limit_expr <- [
          %AST.Node.Literal{value: -1},
          %AST.Node.Literal{value: "x"},
          %AST.Node.Identifier{name: "a"},
        ] do
      assert_raise ArgumentError, message, fn ->
        query_plan(%{statement | limit_expr: limit_expr})
      end

      assert_raise ArgumentError, message, fn ->
        query_plan(%{
          statement
          | limit_expr: limit_expr,
            order_by_exprs: [%AST.Node.Identifier{name: "a"}],
        })
      end
    end
  end
end

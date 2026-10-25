defmodule Guardian.Query.Planner do
  alias Guardian.AST.Node.Statements.SelectStatement

  def query_plan(
        %SelectStatement{order_by_exprs: order_by_exprs, limit_expr: limit_expr} = statement
      )
      when limit_expr != nil and order_by_exprs != nil do
    {sort_exprs, directions} = split_order_by(order_by_exprs)
    statement = update_in(statement.select_exprs, &(sort_exprs ++ &1))
    statement = put_in(statement.order_by_exprs, nil)
    statement = put_in(statement.limit_expr, nil)
    # Plan the rest first, so its errors come first.
    query_plan(statement) ++ [{:order_by_limit, directions, limit!(limit_expr)}]
  end

  def query_plan(%SelectStatement{limit_expr: limit_expr} = statement) when limit_expr != nil do
    statement = put_in(statement.limit_expr, nil)
    query_plan(statement) ++ [{:limit, limit!(limit_expr)}]
  end

  def query_plan(%SelectStatement{order_by_exprs: order_by_exprs} = statement)
      when order_by_exprs != nil do
    {sort_exprs, directions} = split_order_by(order_by_exprs)
    statement = update_in(statement.select_exprs, &(sort_exprs ++ &1))
    statement = put_in(statement.order_by_exprs, nil)
    query_plan(statement) ++ [{:order_by, directions}]
  end

  def query_plan(%SelectStatement{having_expr: having_expr} = statement)
      when having_expr != nil do
    {old_exprs, keys, new_exprs} =
      [having_expr | statement.select_exprs]
      |> Enum.flat_map(&aggregate_exprs/1)
      |> Enum.uniq()
      |> Enum.with_index()
      |> Enum.map(fn {old_expr, i} ->
        key = "v#{i}"
        new_expr = %Guardian.AST.Node.Identifier{name: key}
        {old_expr, key, new_expr}
      end)
      |> SuperList.unzip()

    statement1 = %SelectStatement{statement | select_exprs: old_exprs, having_expr: nil}

    statement2 = %SelectStatement{
      select_exprs: Enum.map(statement.select_exprs, &substitute(&1, old_exprs, new_exprs)),
      from_expr: %Guardian.AST.Node.Literal{value: "_stream"},
      where_expr: substitute(having_expr, old_exprs, new_exprs),
    }

    query_plan(statement1) ++
      [{:reassemble_segments, Enum.zip(keys, old_exprs)}] ++ query_plan(statement2)
  end

  def query_plan(%SelectStatement{group_by_exprs: group_by_exprs} = statement)
      when group_by_exprs != nil do
    reselect_required =
      Enum.any?(statement.select_exprs, fn expr ->
        aggregate_exprs(expr) != [expr]
      end)

    if reselect_required do
      statement1 = %SelectStatement{
        statement
        | having_expr: %Guardian.AST.Node.Literal{value: true},
      }

      query_plan(statement1)
    else
      {aggregate_args, aggregate_names_and_arities} =
        Enum.map(statement.select_exprs, fn
          %Guardian.AST.Node.AggregateFunctionCall{name: name, args: args} ->
            # false = Enum.any?(args, &contains_aggregate_expr/1)
            {args, {name, length(args)}}

          expr ->
            # false = contains_aggregate_expr(expr)
            {[expr], {"arbitrary", 1}}
        end)
        |> Enum.unzip()

      default_step =
        if statement.group_by_exprs == [%Guardian.AST.Node.Literal{value: nil}] do
          {aggregate_names, _arities} = Enum.unzip(aggregate_names_and_arities)

          default_row =
            Enum.map(
              aggregate_names,
              &Guardian.Aggregation.default(Guardian.Aggregation.fetch!(&1))
            )

          [{:default, default_row}]
        else
          []
        end

      statement1 = %SelectStatement{
        statement
        | select_exprs: statement.group_by_exprs ++ Enum.concat(aggregate_args),
          group_by_exprs: nil,
      }

      query_plan(statement1) ++
        [{:group_by, statement.group_by_exprs, aggregate_names_and_arities}] ++ default_step
    end
  end

  def query_plan(%SelectStatement{select_exprs: select_exprs, where_expr: where_expr} = statement)
      when select_exprs != nil and where_expr != nil do
    if Enum.any?(select_exprs, &has_aggregate_function_call/1) do
      query_plan(%SelectStatement{
        statement
        | group_by_exprs: [%Guardian.AST.Node.Literal{value: nil}],
      })
    else
      statement = put_in(statement.select_exprs, nil)
      statement = put_in(statement.where_expr, nil)
      query_plan(statement) ++ [{:select_where, select_exprs, where_expr}]
    end
  end

  def query_plan(%SelectStatement{where_expr: where_expr} = statement) when where_expr != nil do
    statement1 = %SelectStatement{
      statement
      | select_exprs: [where_expr | statement.select_exprs],
        where_expr: nil,
    }

    query_plan(statement1) ++ [{:where, where_expr}]
  end

  def query_plan(%SelectStatement{select_exprs: select_exprs} = statement)
      when select_exprs != nil do
    if Enum.any?(select_exprs, &has_aggregate_function_call/1) do
      query_plan(%SelectStatement{
        statement
        | group_by_exprs: [%Guardian.AST.Node.Literal{value: nil}],
      })
    else
      statement1 = %SelectStatement{statement | select_exprs: nil}
      query_plan(statement1) ++ [{:select, select_exprs}]
    end
  end

  def query_plan(
        %SelectStatement{from_expr: %Guardian.AST.Node.Literal{value: "_stream"}} = statement
      ) do
    statement = %SelectStatement{statement | from_expr: nil}

    # Assert all other fields null.
    ^statement = %SelectStatement{}
    []
  end

  def query_plan(
        %SelectStatement{from_expr: %Guardian.AST.Node.Identifier{} = from_expr} = statement
      ) do
    statement = %SelectStatement{statement | from_expr: nil}

    # Assert all other fields null.
    ^statement = %SelectStatement{}

    [{:from, from_expr}]
  end

  def query_plan(%SelectStatement{from_expr: nil = from_expr} = statement) do
    # Assert all other fields null.
    ^statement = %SelectStatement{}

    [{:from, from_expr}]
  end

  defp substitute(expr, from_exprs, to_exprs) do
    replacement_map = Enum.zip(from_exprs, to_exprs) |> Map.new()

    Guardian.AST.prewalk(expr, fn expr ->
      case Map.fetch(replacement_map, expr) do
        {:ok, replacement} -> replacement
        :error -> expr
      end
    end)
  end

  defp aggregate_exprs(expr) do
    {_expr, exprs} =
      Guardian.AST.prewalk(expr, [], fn
        %Guardian.AST.Node.AggregateFunctionCall{} = expr, acc ->
          {%Guardian.AST.Node.Literal{value: nil}, [expr | acc]}

        %Guardian.AST.Node.Identifier{} = expr, acc ->
          {expr, [expr | acc]}

        expr, acc ->
          {expr, acc}
      end)

    exprs
  end

  defp has_aggregate_function_call(expr) do
    {_expr, result} =
      Guardian.AST.prewalk(expr, false, fn
        %Guardian.AST.Node.AggregateFunctionCall{} = expr, _result ->
          {expr, true}

        expr, acc ->
          {expr, acc}
      end)

    result
  end

  # The expressions to sort by, selected ahead of the statement's own, and the
  # direction of each (`Guardian.Query.Sorting`'s `:asc` or `:desc`; ascending unless DESC).
  defp split_order_by(order_by_exprs) do
    order_by_exprs
    |> Enum.map(fn
      %Guardian.AST.Node.Ascending{left: expr} -> {expr, :asc}
      %Guardian.AST.Node.Descending{left: expr} -> {expr, :desc}
      expr -> {expr, :asc}
    end)
    |> Enum.unzip()
  end

  # The parser gives LIMIT a non-negative integer literal; only a statement built by
  # hand can have anything else.
  defp limit!(%Guardian.AST.Node.Literal{value: limit}) when is_integer(limit) and limit >= 0 do
    limit
  end

  defp limit!(limit_expr) do
    raise ArgumentError,
          "LIMIT must be a non-negative integer literal, got: " <>
            inspect(limit_expr, limit: 5, printable_limit: 100)
  end
end

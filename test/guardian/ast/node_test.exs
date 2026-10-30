defmodule Guardian.AST.NodeTest do
  use ExUnit.Case, async: true
  import Guardian.AST.Node

  alias Guardian.AST.Node.Literal

  # Walks every literal, doubling integers and recording each original value, so the
  # result shows both the rebuilt node and the accumulator threaded through in order.
  defp double_and_count(expr, fields) do
    pre = fn
      %Literal{value: value} = literal, acc when is_integer(value) ->
        {%Literal{literal | value: value * 2}, [value | acc]}

      expr, acc ->
        {expr, acc}
    end

    post = fn expr, acc -> {expr, acc} end
    traverse_fields(expr, fields, [], pre, post)
  end

  test "traverse_fields walks single nodes and lists in field order and skips nil" do
    expr = %Guardian.AST.Node.Case{
      case_exprs: nil,
      when_exprs: [%Literal{value: 1}, %Literal{value: 2}],
      then_exprs: [%Literal{value: 3}, %Literal{value: 4}],
      else_expr: %Literal{value: 5},
    }

    {expr, visited} = double_and_count(expr, [:case_exprs, :when_exprs, :then_exprs, :else_expr])

    assert visited == [5, 4, 3, 2, 1]
    assert expr.case_exprs == nil
    assert expr.when_exprs == [%Literal{value: 2}, %Literal{value: 4}]
    assert expr.then_exprs == [%Literal{value: 6}, %Literal{value: 8}]
    assert expr.else_expr == %Literal{value: 10}

    # Fields not listed are left alone.
    {expr, visited} = double_and_count(expr, [:else_expr])
    assert visited == [10]
    assert expr.when_exprs == [%Literal{value: 2}, %Literal{value: 4}]
    assert expr.else_expr == %Literal{value: 20}
  end
end

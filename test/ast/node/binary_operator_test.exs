defmodule AST.Node.BinaryOperatorTest do
  use ExUnit.Case, async: true

  alias AST.Node.Identifier
  alias AST.Node.Operators

  @symbols [
    {AST.Node.As, "AS"},
    {Operators.AddOperator, "+"},
    {Operators.AndOperator, "AND"},
    {Operators.ConcatOperator, "||"},
    {Operators.DivideOperator, "/"},
    {Operators.EqualOperator, "="},
    {Operators.GreaterThanOperator, ">"},
    {Operators.GreaterThanOrEqualOperator, ">="},
    {Operators.IlikeOperator, "ILIKE"},
    {Operators.InOperator, "IN"},
    {Operators.IsNotOperator, "IS NOT"},
    {Operators.IsOperator, "IS"},
    {Operators.LessThanOperator, "<"},
    {Operators.LessThanOrEqualOperator, "<="},
    {Operators.LikeOperator, "LIKE"},
    {Operators.MultiplyOperator, "*"},
    {Operators.NotEqualOperator, "!="},
    {Operators.NotIlikeOperator, "NOT ILIKE"},
    {Operators.NotLikeOperator, "NOT LIKE"},
    {Operators.NotRlikeOperator, "NOT RLIKE"},
    {Operators.NullSafeEqualOperator, "<=>"},
    {Operators.OrOperator, "OR"},
    {Operators.RlikeOperator, "RLIKE"},
    {Operators.SubtractOperator, "-"},
  ]

  for {mod, symbol} <- @symbols do
    test "#{inspect(mod)} prints left #{symbol} right and traverses left then right" do
      mod = unquote(mod)
      symbol = unquote(symbol)
      expr = struct!(mod, left: %Identifier{name: "a"}, right: %Identifier{name: "b"})
      assert AST.unparse(expr) == "a #{symbol} b"

      {_, visited} =
        AST.postwalk(expr, [], fn expr, acc -> {expr, acc ++ [AST.unparse(expr)]} end)

      assert visited == ["a", "b", "a #{symbol} b"]

      # Rewritten children are put back.
      rewritten =
        AST.prewalk(expr, fn
          %Identifier{name: "a"} -> %Identifier{name: "z"}
          expr -> expr
        end)

      assert AST.unparse(rewritten) == "z #{symbol} b"

      assert_raise ArgumentError, fn -> struct!(mod, left: %Identifier{name: "a"}) end
      assert_raise ArgumentError, fn -> struct!(mod, right: %Identifier{name: "b"}) end
    end
  end
end

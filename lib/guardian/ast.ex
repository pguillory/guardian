defmodule Guardian.AST do
  @moduledoc """
  Abstract Syntax Tree utilities for Guardian's query language.

  AST provides a unified interface for parsing, traversing, and manipulating syntax
  trees used by queries. All AST nodes are Elixir structs that
  implement common protocols.

  ## Parsing

      iex> Guardian.AST.parse_expression("amount + tax")
      {:ok, %Guardian.AST.Node.Operators.AddOperator{left: %Guardian.AST.Node.Identifier{name: "amount"}, right: %Guardian.AST.Node.Identifier{name: "tax"}}}

      iex> Guardian.AST.parse_statements("SELECT amount + tax FROM transactions")
      {:ok, [%Guardian.AST.Node.Statements.SelectStatement{...}]}

  Bad input returns `{:error, %Guardian.AST.ParseError{}}`.

  ## Unparsing (Converting back to source)

      iex> {:ok, expr} = Guardian.AST.parse_expression("amount + tax")
      iex> Guardian.AST.unparse(expr)
      "amount + tax"

  ## Traversal

  AST provides tree traversal utilities similar to Elixir's `Macro` module:

  - `traverse/4` - Full control with pre and post functions
  - `prewalk/2` - Visit nodes before children
  - `postwalk/2` - Visit nodes after children

  ## AST Node Types

  All AST nodes are structs defined in their own modules:

  ### Statements
  - `SelectStatement` - SELECT queries

  ### Expressions
  - `Identifier` - Column/table names
  - `Literal` - Scalar values (null, boolean, integer, float, string)
  - `ListLiteral` - List of values
  - `FunctionCall` - Function invocations
  - `AggregateFunctionCall` - Aggregation functions

  ### Operators
  - Arithmetic: `AddOperator`, `SubtractOperator`, `MultiplyOperator`, `DivideOperator`
  - Comparison: `EqualOperator`, `LessThanOperator`, `GreaterThanOperator`, etc.
  - Logical: `AndOperator`, `OrOperator`, `NotOperator`
  - String: `ConcatOperator`, `LikeOperator`

  Each node module implements the `Guardian.AST.Node` behaviour (`traverse/4`, `to_source/1`).

  Node modules live under `lib/guardian/ast/node/`; `Guardian.AST.Node` is their contract.
  """

  alias Guardian.AST.Parser

  def parse(source) do
    Parser.parse(source)
  end

  def parse_statements(source) do
    Parser.parse_statements(source)
  end

  def parse_expression(source) do
    Parser.parse_expression(source)
  end

  def unparse(%mod{} = expr) do
    mod.to_source(expr)
  end

  def traverse(expr, acc, pre, post) do
    {expr, acc} = pre.(expr, acc)
    %mod{} = expr
    {expr, acc} = mod.traverse(expr, acc, pre, post)
    {expr, acc} = post.(expr, acc)
    {expr, acc}
  end

  def prewalk(expr, acc, func) do
    post = fn x, acc -> {x, acc} end
    traverse(expr, acc, func, post)
  end

  def prewalk(expr, func) do
    {expr, nil} = prewalk(expr, nil, fn expr, nil -> {func.(expr), nil} end)
    expr
  end

  def postwalk(expr, acc, func) do
    pre = fn x, acc -> {x, acc} end
    traverse(expr, acc, pre, func)
  end

  def postwalk(expr, func) do
    {expr, nil} = postwalk(expr, nil, fn expr, nil -> {func.(expr), nil} end)
    expr
  end

  def valid_identifier(source) do
    match?({:ok, %Guardian.AST.Node.Identifier{}}, Guardian.AST.parse_expression(source))
  end
end

defmodule AST.Node do
  @moduledoc """
  The contract every AST node module implements; `use AST.Node` declares it and
  imports `traverse_fields/5`.

  Every node defines `to_source/1` (`AST.unparse/1`) and `traverse/4`
  (`AST.traverse/4`). An expression node that can be evaluated implements the
  `Query.Eval` protocol in its own module (`defimpl Query.Eval do ... end`), or
  defines `rewrite/1` to an equivalent node that can, which `Query.Eval`'s fallback
  evaluates instead. A node that does neither (a splat, ASC and DESC, an aggregate
  call, a statement) is not evaluated as an expression; the planner handles it, and
  evaluating one raises `Query.Error`.
  """

  @typedoc "An AST node: a struct whose module implements this behaviour."
  @type t :: struct()

  @typedoc "What a traversal threads through `pre` and `post`."
  @type acc :: term()

  @typedoc "A `pre` or `post` function: a node and the accumulator, to both, updated."
  @type visitor :: (t(), acc() -> {t(), acc()})

  @doc "The node as query source text."
  @callback to_source(t()) :: String.t()

  @doc """
  Traverses the node's children with `AST.traverse/4`, in a fixed order, and returns
  the node with its children replaced. Childless nodes return `{node, acc}`.
  """
  @callback traverse(t(), acc(), pre :: visitor(), post :: visitor()) :: {t(), acc()}

  @doc "An equivalent node to evaluate in this one's place."
  @callback rewrite(t()) :: t()

  @optional_callbacks rewrite: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour AST.Node
      import AST.Node, only: [traverse_fields: 5]
    end
  end

  @doc """
  Traverses `fields` of `expr` in order with `AST.traverse/4` and puts the results
  back. A field holding `nil` is skipped, one holding a list is traversed element by
  element, and any other value is traversed as one node.
  """
  @spec traverse_fields(t(), [atom()], acc(), visitor(), visitor()) :: {t(), acc()}
  def traverse_fields(expr, fields, acc, pre, post) do
    Enum.reduce(fields, {expr, acc}, fn field, {expr, acc} ->
      {value, acc} = traverse_value(Map.fetch!(expr, field), acc, pre, post)
      {%{expr | field => value}, acc}
    end)
  end

  defp traverse_value(nil, acc, _pre, _post) do
    {nil, acc}
  end

  defp traverse_value(exprs, acc, pre, post) when is_list(exprs) do
    Enum.map_reduce(exprs, acc, &AST.traverse(&1, &2, pre, post))
  end

  defp traverse_value(expr, acc, pre, post) do
    AST.traverse(expr, acc, pre, post)
  end
end

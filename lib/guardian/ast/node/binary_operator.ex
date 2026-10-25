defmodule Guardian.AST.Node.BinaryOperator do
  @moduledoc """
  The shared shape of a two-operand infix node: `use Guardian.AST.Node.BinaryOperator,
  symbol: "<"` makes the module an `Guardian.AST.Node` with `@enforce_keys` and a struct of
  `[:left, :right]`, `symbol/0` returning the symbol, `to_source/1` printing
  `left SYM right`, and `traverse/4` over `left` then `right`. `Guardian.AST.Parser` reads
  `symbol/0` for the operator's syntax, so parsing and printing use one spelling.
  The module keeps only what is special about it: its `Guardian.Query.Eval` implementation,
  `eval/2` or `rewrite/1`. `Guardian.AST.Node.As` uses it too: it is not an operator, but it
  has the same shape.
  """

  defmacro __using__(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    separator = " " <> symbol <> " "

    quote do
      use Guardian.AST.Node

      @enforce_keys [:left, :right]
      defstruct [:left, :right]

      def symbol do
        unquote(symbol)
      end

      def to_source(%__MODULE__{left: left, right: right}) do
        Guardian.AST.unparse(left) <> unquote(separator) <> Guardian.AST.unparse(right)
      end

      def traverse(%__MODULE__{} = expr, acc, pre, post) do
        traverse_fields(expr, [:left, :right], acc, pre, post)
      end
    end
  end
end

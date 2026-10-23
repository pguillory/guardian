defprotocol Query.Eval do
  @moduledoc """
  Evaluates an AST expression node against a context: a `Query.Evaluation`
  segment snapshot, or an event map (empty for constant folding).

  Each evaluable node implements this protocol in its own file, next to its struct
  (`defimpl Query.Eval do ... end` inside the node module). A node that only rewrites
  to an equivalent node (`AST.Node`'s `rewrite/1`) needs no implementation: the `Any`
  implementation evaluates the rewrite's result. A node that does neither (a splat,
  ASC or DESC, an aggregate call) cannot be evaluated as an expression, and evaluating
  one raises `Query.Error`.

  Code that wants a plain column or value uses `Query.Evaluation.eval/2`, which unpacks
  the result.
  """

  @fallback_to_any true

  @doc """
  Evaluates `expr` against `context`: to a packed column for a segment snapshot, or a
  `Query.Constant` (always, for an event map; for a snapshot when every row has the
  same value).
  """
  @spec eval(t(), term()) :: binary() | %Query.Constant{}
  def eval(expr, context)
end

defimpl Query.Eval, for: Any do
  def eval(%mod{} = expr, context) do
    Code.ensure_loaded!(mod)

    if function_exported?(mod, :rewrite, 1) do
      Query.Eval.eval(mod.rewrite(expr), context)
    else
      raise Query.Error,
        message: "#{AST.unparse(expr)} cannot be evaluated as an expression"
    end
  end
end

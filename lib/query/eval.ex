defprotocol Guardian.Query.Eval do
  @moduledoc """
  Evaluates an AST expression node against a context: a `Guardian.Query.Evaluation`
  segment snapshot, or an event map (empty for constant folding).

  Each evaluable node implements this protocol in its own file, next to its struct
  (`defimpl Guardian.Query.Eval do ... end` inside the node module). A node that only rewrites
  to an equivalent node (`Guardian.AST.Node`'s `rewrite/1`) needs no implementation: the `Any`
  implementation evaluates the rewrite's result. A node that does neither (a splat,
  ASC or DESC, an aggregate call) cannot be evaluated as an expression, and evaluating
  one raises `Guardian.Query.Error`.

  Code that wants a plain column or value uses `Guardian.Query.Evaluation.eval/2`, which unpacks
  the result.
  """

  @fallback_to_any true

  @doc """
  Evaluates `expr` against `context`: to a packed column for a segment snapshot, or a
  `Guardian.Query.Constant` (always, for an event map; for a snapshot when every row has the
  same value).
  """
  @spec eval(t(), term()) :: binary() | %Guardian.Query.Constant{}
  def eval(expr, context)
end

defimpl Guardian.Query.Eval, for: Any do
  def eval(%mod{} = expr, context) do
    Code.ensure_loaded!(mod)

    if function_exported?(mod, :rewrite, 1) do
      Guardian.Query.Eval.eval(mod.rewrite(expr), context)
    else
      raise Guardian.Query.Error,
        message: "#{Guardian.AST.unparse(expr)} cannot be evaluated as an expression"
    end
  end
end

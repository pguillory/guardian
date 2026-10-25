defmodule Guardian.Rules.Step.Lookup do
  @moduledoc "A parsed LOOKUP; target is bound only after whole-set validation."
  defstruct [
    :table,
    :file,
    :line,
    :index,
    :field,
    :source,
    :counter,
    :target_table,
    :where_expr,
    :target,
    kind: :lookup,
    by_exprs: [],
    reads: [],
  ]
end

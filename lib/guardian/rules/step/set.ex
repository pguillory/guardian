defmodule Guardian.Rules.Step.Set do
  @moduledoc "A parsed SET's inputs and diagnostic location."
  defstruct [
    :table,
    :file,
    :line,
    :index,
    :field,
    :source,
    :value_expr,
    :where_expr,
    kind: :set,
    reads: [],
  ]
end

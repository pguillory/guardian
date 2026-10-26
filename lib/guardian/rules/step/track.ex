defmodule Guardian.Rules.Step.Track do
  @moduledoc """
  A parsed TRACK's expressions and source location. Its `Guardian.Counters.Definition`
  owns the counter metadata from construction; Validation checks it before plan
  construction.
  """
  defstruct [
    :table,
    :file,
    :line,
    :index,
    :field,
    :source,
    :aggregate_expr,
    :where_expr,
    :definition,
    kind: :track,
    by_exprs: [],
    reads: [],
  ]
end

defmodule Guardian.Rules.Step.Track do
  @moduledoc """
  A parsed TRACK with definition identity and window coordinates.
  Aggregation and definition are nil until validated plan construction resolves
  the configuration and prepares immutable counter metadata.
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
    :operator,
    :aggregation,
    :window_ms,
    :bucket_ms,
    :identity,
    :definition,
    kind: :track,
    by_exprs: [],
    reads: [],
  ]
end

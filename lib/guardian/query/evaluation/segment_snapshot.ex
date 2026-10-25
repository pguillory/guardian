defmodule Guardian.Query.Evaluation.SegmentSnapshot do
  @moduledoc """
  Snapshot of a segment for query evaluation, with its row count.

  Exactly one of `segment` and `columns` is set. `segment` is a stored segment's ID;
  every column read resolves it through Guardian.Storage. `columns` is a query
  temporary (the one row of a SELECT without FROM, the `schema` table, or
  reassembled GROUP BY output): a map from key to packed column binary. Temporaries
  are plain data, so no process has to be stopped when the query ends.
  """

  @enforce_keys [:count]
  defstruct segment: nil, columns: nil, count: nil
end

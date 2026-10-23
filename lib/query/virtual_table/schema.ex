defmodule Query.VirtualTable.Schema do
  alias Query.Evaluation.SegmentSnapshot
  alias Storage.Column
  alias Storage.Column.Metadata
  require Metadata

  def snapshots do
    rows =
      Cluster.Metadata.schemas()
      |> Enum.sort()
      |> Enum.flat_map(fn {table, schema} ->
        Enum.map(schema, fn {key, column_metadata} ->
          [
            Metadata.tuple(
              count: count,
              null_count: null_count,
              false_count: false_count,
              true_count: true_count,
              int_count: int_count,
              float_count: float_count,
              string_count: string_count
            )
            | _,
          ] = column_metadata

          %{
            "table" => table,
            "key" => key,
            "count" => count,
            "null_count" => null_count,
            "false_count" => false_count,
            "true_count" => true_count,
            "int_count" => int_count,
            "float_count" => float_count,
            "string_count" => string_count,
          }
        end)
      end)

    # Plain data, not a Segment process: nothing to stop when the query ends.
    columns = Map.new(keys(), fn key -> {key, Column.from_list(Enum.map(rows, & &1[key]))} end)
    [%SegmentSnapshot{columns: columns, count: length(rows)}]
  end

  def keys do
    [
      "table",
      "key",
      "count",
      "null_count",
      "false_count",
      "true_count",
      "int_count",
      "float_count",
      "string_count",
    ]
  end
end

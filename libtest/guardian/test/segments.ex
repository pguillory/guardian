defmodule Guardian.Test.Segments do
  @moduledoc """
  Builds segment fixtures. Tests must isolate their
  segments, filenames and tables.
  """

  @doc """
  Appends a row that may be nested to `segment`, flattening it first as
  `Guardian.Storage.append/2` does (`Guardian.Storage.Segment.append/2` takes flat rows).
  """
  def segment_append(segment, row) do
    Guardian.Storage.Segment.append(
      segment,
      Guardian.Storage.Flattening.flatten_event(Map.new(row))
    )
  end

  @doc """
  `{:ok, row}` with the flat row at `offset` in `segment`, read column by column
  (`keys`, then `get_column` for each) and leaving out keys whose value there is nil,
  or `{:error, :not_found}` past the last row. For Storage tests only
  (`lib/guardian/storage/AGENTS.md`), which may read Segment internals; other tests
  read results through queries. The reads are separate calls, not one snapshot, so
  rows appended meanwhile can add keys.
  """
  def segment_row(segment, offset) when is_integer(offset) and offset >= 0 do
    {:ok, count} = Guardian.Storage.Segment.count(segment)

    if offset < count do
      {:ok, keys} = Guardian.Storage.Segment.keys(segment)

      row =
        Enum.reduce(keys, %{}, fn key, row ->
          {:ok, column} = Guardian.Storage.Segment.get_column(segment, key)

          case column |> Guardian.Storage.Column.to_list() |> Enum.at(offset) do
            nil -> row
            value -> Map.put(row, key, value)
          end
        end)

      {:ok, row}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Writes a segment file holding flat `rows` to `filename`, packing their columns
  directly (no segment process, so it can write into any directory, such as a peer's),
  and returns `filename`. The caller removes the file.
  """
  def write_segment_file(filename, rows) do
    keys = rows |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()

    columns =
      Enum.map(keys, fn key ->
        rows |> Enum.map(&Map.get(&1, key)) |> Guardian.Storage.Column.from_list()
      end)

    :ok = Guardian.Storage.SegmentFile.write(filename, length(rows), keys, columns)
    filename
  end

  @doc """
  Persists every segment of `table`: its writable segments are rotated out as if full,
  and the call returns once each segment has written its file and serves from it. For
  Storage and query tests that need rows on disk.
  """
  def await_persisted(table) do
    for segment <- Guardian.Storage.MutableSegments.get_mutable_segments(table) do
      :ok = Guardian.Storage.MutableSegments.segment_is_full(table, segment)
    end

    for segment_id <- Guardian.Storage.segment_ids(table),
        {:ok, segment} <- [Guardian.Storage.get_segment(segment_id)] do
      # Messages from one sender arrive in order, so the read returns after this
      # persist has run (MutableSegments' may have run already, which is the same).
      :ok = Guardian.Storage.Segment.persist(segment)
      {:ok, _count} = Guardian.Storage.Segment.count(segment)
    end

    :ok
  end
end

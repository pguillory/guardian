defmodule Guardian.Storage.SegmentFile do
  # Internal to Storage; see lib/guardian/storage/AGENTS.md, "Public boundary".
  @moduledoc false

  # The on-disk segment format: file names and contents. No process logic; Segment
  # writes and loads through here. The layout is described in
  # docs/architecture/system.md section 4.3 and pinned by
  # test/guardian/storage/segment_file_golden_test.exs. Don't change it as a side effect of other
  # work (lib/guardian/storage/AGENTS.md).
  #
  # A file is a primary header of nine big-endian 64-bit integers (the row count, then
  # the byte size of each secondary-header column), the secondary header (the keys,
  # six per-type count columns, and each stored column's byte size, one entry per
  # stored column), then the packed columns in key order. The count columns are
  # written for the format but not read: a column's metadata comes from its bytes.

  alias Guardian.Storage.BlobStore
  alias Guardian.Storage.Column

  @primary_header_size 72

  @doc """
  The path of a segment's file: `{segment_dir}/{table}.{segment_id}.seg`.
  """
  def filename(table, segment_id) when is_binary(segment_id) do
    basename = [table, segment_id, "seg"] |> Enum.join(".")
    Path.join(Guardian.Storage.segment_dir(), basename)
  end

  @doc """
  `{:ok, table, segment_id}` for a valid segment filename, otherwise `:error`. Only
  generated segment IDs (32 uppercase hex digits) are accepted.
  """
  def parse_filename(filename) do
    with [table, segment_id, "seg"] when table != "" <-
           Path.basename(filename) |> String.split("."),
         true <- Regex.match?(~r/\A[0-9A-F]{32}\z/, segment_id) do
      {:ok, table, segment_id}
    else
      _ -> :error
    end
  end

  @doc """
  Returns the `.seg` files that are not valid segment filenames and will be ignored,
  such as segments written in the older `{user_id}.{table}.{segment_id}.seg` format.
  """
  def unparseable(filenames) do
    Enum.filter(filenames, fn filename ->
      String.ends_with?(filename, ".seg") and parse_filename(filename) == :error
    end)
  end

  @doc """
  Writes a segment file holding `count` rows: `keys` and their packed `columns`, in the
  same order. Returns what `BlobStore.write/2` returns.
  """
  def write(filename, count, keys, columns) do
    keys_column = keys |> Column.from_list()
    null_counts_column = columns |> Enum.map(&Column.null_count/1) |> Column.from_list()
    false_counts_column = columns |> Enum.map(&Column.false_count/1) |> Column.from_list()
    true_counts_column = columns |> Enum.map(&Column.true_count/1) |> Column.from_list()
    int_counts_column = columns |> Enum.map(&Column.int_count/1) |> Column.from_list()
    float_counts_column = columns |> Enum.map(&Column.float_count/1) |> Column.from_list()
    string_counts_column = columns |> Enum.map(&Column.string_count/1) |> Column.from_list()
    sizes_column = columns |> Enum.map(&byte_size/1) |> Column.from_list()

    primary_header = <<
      count::size(64),
      byte_size(keys_column)::size(64),
      byte_size(null_counts_column)::size(64),
      byte_size(false_counts_column)::size(64),
      byte_size(true_counts_column)::size(64),
      byte_size(int_counts_column)::size(64),
      byte_size(float_counts_column)::size(64),
      byte_size(string_counts_column)::size(64),
      byte_size(sizes_column)::size(64)
    >>

    secondary_header = [
      keys_column,
      null_counts_column,
      false_counts_column,
      true_counts_column,
      int_counts_column,
      float_counts_column,
      string_counts_column,
      sizes_column,
    ]

    BlobStore.write(filename, [primary_header, secondary_header | columns])
  end

  @doc """
  Maps a segment file and returns `{:ok, count, columns}`, where `columns` maps each
  key to its packed column (sub-binaries of the mapping), or `{:error, reason}` for a
  file that cannot be loaded: `{:mmap, posix}` when it cannot be opened or mapped,
  otherwise the failure's kind (an exception module, or `:throw`/`:exit`).

  Every column's metadata is computed here so that a truncated, empty, or malformed
  file fails now rather than later in a call. The reason names only the failure's
  kind, never the exception's message or arguments, which can contain segment data.
  Corrupt column bytes that trip an assert in the column NIF still abort the VM: packed
  columns are not yet validated before the NIF reads them.
  """
  def read(filename) do
    {count, columns} = decode(filename)
    Enum.each(columns, fn {_key, column} -> Column.metadata(column) end)
    {:ok, count, columns}
  rescue
    exception -> {:error, exception.__struct__}
  catch
    :throw, {:mmap, posix} -> {:error, {:mmap, posix}}
    kind, _reason -> {:error, kind}
  end

  defp decode(filename) do
    serialized_segment =
      case Guardian.Storage.Mmap.read(filename) do
        {:ok, binary} -> binary
        {:error, posix} -> throw({:mmap, posix})
      end

    primary_header = binary_part(serialized_segment, 0, @primary_header_size)

    <<
      count::size(64),
      keys_column_size::size(64),
      null_counts_column_size::size(64),
      false_counts_column_size::size(64),
      true_counts_column_size::size(64),
      int_counts_column_size::size(64),
      float_counts_column_size::size(64),
      string_counts_column_size::size(64),
      sizes_column_size::size(64)
    >> = primary_header

    counts_columns_size =
      null_counts_column_size + false_counts_column_size + true_counts_column_size +
        int_counts_column_size + float_counts_column_size + string_counts_column_size

    secondary_header_size = keys_column_size + counts_columns_size + sizes_column_size

    secondary_header =
      binary_part(serialized_segment, @primary_header_size, secondary_header_size)

    <<
      keys_column::binary-size(^keys_column_size),
      _counts_columns::binary-size(^counts_columns_size),
      sizes_column::binary-size(^sizes_column_size)
    >> = secondary_header

    keys = keys_column |> Column.to_list()
    sizes = sizes_column |> Column.to_list()

    {stored_columns, _total_file_size} =
      Enum.map_reduce(sizes, @primary_header_size + secondary_header_size, fn size, offset ->
        stored_column = binary_part(serialized_segment, offset, size)
        {stored_column, offset + size}
      end)

    {count, Enum.zip(keys, stored_columns) |> Map.new()}
  end
end

defmodule Guardian.Storage do
  @moduledoc """
  Main storage layer interface for Guardian's custom columnar event storage.

  Storage keeps events in segments (columnar batches of up to 16K events), each one
  process for its whole life: writable in memory, then frozen, then written to its
  `.seg` file and served from the memory-mapped file. `ReadableSegments` registers every
  segment and `MutableSegments` the writable ones (see `lib/guardian/storage/AGENTS.md`).

  Operations are scoped by `table`. Guardian is single-user; there is no namespace.

  ## Public API

  This module is Storage's boundary. Code outside `lib/guardian/storage` calls only the
  functions documented here (and the data modules `Guardian.Storage.Column`,
  `Guardian.Storage.Column.Metadata`, `Guardian.Storage.Value` and `Guardian.Storage.Flattening`), names segments
  by ID, and never holds a segment's PID. The segment processes, their registries and
  `Guardian.Storage.Schema` are internal (see `lib/guardian/storage/AGENTS.md`).

  - `append/2`, `append_flattened/2`, `append_flattened_result/2` - Store a row
  - `segment_ids/1` - The IDs of a table's segments on this node
  - `segment_row_count/1`, `get_column/2` - Read a segment by ID
  - `schema/1`, `table_names/0`, `merge_schemas/2` - Inferred schemas
  - `delete_table/1`, `delete_segment/1` - Delete segments
  - `table_row_count/1`, `dump_table/1` - Expensive whole-table reads (tests)
  - `native_counts/0` - Live file mappings and native columns, for `system_stats`
  - `ready?/0`, `data_dir/0`, `segment_dir/0`

  ## Storage Locations

  Segments live in `{data_dir}/segments/`, where `data_dir` is `:guardian, :data_dir`:

  - Development: `{cwd}/data/dev`
  - Test: a fresh directory under the system temp directory for each run, removed
    when the run ends
  - Production: `GUARDIAN_DATA_DIR`, default `/root/data` (`/data` on Fly.io)

  See `ARCHITECTURE.md` for detailed storage architecture documentation.
  """

  alias Guardian.Storage.Column
  alias Guardian.Storage.Flattening
  alias Guardian.Storage.Mmap
  alias Guardian.Storage.MutableSegments
  alias Guardian.Storage.ReadableSegments
  alias Guardian.Storage.Schema
  alias Guardian.Storage.Segment
  require Guardian.SegmentID
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # The segments run under SegmentSupervisor, a DynamicSupervisor, with ReadableSegments
  # and MutableSegments, their registries, in a `:one_for_all` group: a crash of any of
  # the three restarts all three, and the restart reloads from disk. Storage itself is
  # `:rest_for_one`, so a Schema crash restarts everything after it.
  #
  # On shutdown (or a restart of the group) SegmentSupervisor stops every segment
  # concurrently, and each writes its file if it has unwritten rows
  # (`Guardian.Storage.Segment.terminate/2`), within the segment's own 90 s budget.
  # The group and SegmentSupervisor are supervisors, with no budget of their own
  # (`:infinity`), so the segments' budget is the one that counts. It must fit inside
  # the platform's stop timeout (Fly `kill_timeout`, 150 s, of which the tunnel
  # connector's drain in bin/fly-start takes up to 10 s, and 20 s at worst, before
  # Guardian gets SIGTERM) with room left for the other children. Past its budget a
  # segment is killed and its unwritten rows are lost.
  @segment_group [
    {DynamicSupervisor, name: Guardian.Storage.SegmentSupervisor},
    ReadableSegments,
    MutableSegments,
  ]

  # Every named Storage process, in start order. `ready?/0` relies on the order: a
  # GenServer registers its name before its `init` runs, so ReadableSegments is
  # registered during its long load, but MutableSegments, started after it, is not
  # registered until the load has finished, also when only the group restarts.
  @names [
    Schema,
    Guardian.Storage.SegmentSupervisor,
    ReadableSegments,
    MutableSegments,
    Guardian.Storage.SegmentExpiration,
  ]

  def init(_opts) do
    children = [
      Schema,
      %{
        id: :segments,
        type: :supervisor,
        shutdown: :infinity,
        start: {Supervisor, :start_link, [@segment_group, [strategy: :one_for_all]]},
      },
      Guardian.Storage.SegmentExpiration,
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Whether every Storage process is running and finished starting, and the machine has
  not begun to stop. False while Storage or one of its children restarts, including the
  segment reload after a restart of the segment registries. Never blocks: it only looks up
  registered names, so it cannot wait on a supervisor that is busy restarting children.
  """
  def ready? do
    not Guardian.Application.stopping?() and Enum.all?(@names, &(Process.whereis(&1) != nil))
  end

  @doc """
  Appends a row (a map or keyword list, possibly nested), flattening it into
  dot-notation keys first. Raises `ArgumentError` if a segment refuses a value.
  """
  def append(table, row) when is_binary(table) do
    append_flattened(table, Flattening.flatten_event(Map.new(row)))
  end

  @doc """
  Appends a row already flattened into dot-notation keys, as produced by
  `Guardian.Storage.Flattening.flatten_event/1`, without flattening it again. Raises
  `ArgumentError` if a segment refuses a value.
  """
  def append_flattened(table, row) when is_binary(table) and is_map(row) do
    case append_flattened_result(table, row) do
      {:error, :invalid_value} -> raise ArgumentError, "value cannot be stored"
      result -> result
    end
  end

  @doc """
  Like `append_flattened/2`, but returns explicit storage refusals as error tuples.
  Exceptions and exits propagate, and do not establish whether the row was stored.
  """
  @spec append_flattened_result(String.t(), map()) :: :ok | {:error, :invalid_value}
  def append_flattened_result(table, row) when is_binary(table) and is_map(row) do
    MutableSegments.append(table, row)
  end

  @doc """
  The IDs of `table`'s segments on this node, newest first. Every segment is registered
  in ReadableSegments from its creation to its deletion.
  """
  def segment_ids(table) when is_binary(table) do
    ReadableSegments.segment_ids(table) |> Enum.reverse()
  end

  # Internal to Storage: code outside `lib/guardian/storage` names segments by ID and reads them
  # with `segment_row_count/1` and `get_column/2`, never holding a segment's PID.
  @doc false
  def get_segment(Guardian.SegmentID.match(segment_id: segment_id)) do
    ReadableSegments.get_segment(segment_id)
  end

  @doc """
  The number of rows in a segment, by ID. Resolves the ID on every call and waits
  without a timeout (a query's time limit bounds it). Returns
  `{:error, {:segment_unavailable, reason}}` if no segment has this ID (`reason` is
  `:not_found`: deleted or expired) or the segment stops during the read (its exit
  reason; name it only with `Guardian.Failure.exit_kind/1`).
  """
  @spec segment_row_count(String.t()) ::
          {:ok, non_neg_integer()} | {:error, {:segment_unavailable, term()}}
  def segment_row_count(segment_id) when is_binary(segment_id) do
    read_segment(segment_id, &Segment.count/1)
  end

  @doc """
  A segment's column, by segment ID, as a packed binary (`Guardian.Storage.Column`): for a
  segment still receiving rows, a snapshot padded to its row count at the time of the
  read. `{:ok, :missing}` if the segment has no such column. Resolves the ID and fails
  like `segment_row_count/1`.
  """
  @spec get_column(String.t(), String.t()) ::
          {:ok, binary()} | {:ok, :missing} | {:error, {:segment_unavailable, term()}}
  def get_column(segment_id, key) when is_binary(segment_id) and is_binary(key) do
    read_segment(segment_id, fn segment ->
      case Segment.get_column(segment, key) do
        {:error, :not_found} -> {:ok, :missing}
        result -> result
      end
    end)
  end

  defp read_segment(segment_id, read) do
    case get_segment(segment_id) do
      {:ok, segment} -> read.(segment)
      {:error, :not_found} -> {:error, {:segment_unavailable, :not_found}}
    end
  end

  def delete_table(table) do
    segment_ids(table)
    |> Enum.each(fn segment_id ->
      :ok = delete_segment(segment_id)
    end)
  end

  def delete_segment(Guardian.SegmentID.match(segment_id: segment_id)) do
    ReadableSegments.delete_segment(segment_id)
  end

  # Very expensive! Don't run in prod.
  def dump_table(table) do
    segment_ids(table)
    |> Enum.flat_map(fn segment_id ->
      {:ok, segment} = get_segment(segment_id)
      count = Segment.count!(segment)
      keys = Segment.keys!(segment)
      events = List.duplicate(%{}, count)

      Enum.reduce(keys, events, fn key, events ->
        column = Segment.get_column!(segment, key)
        values = column |> Column.to_list() |> Flattening.pad(count, nil)

        SuperList.map(events, values, fn
          event, nil -> event
          event, value -> Map.put(event, key, value)
        end)
      end)
    end)
    |> Enum.sort()
  end

  @doc """
  The schema of `table` on this node: its frozen segments' (from
  `Guardian.Storage.Schema`) merged with each writable segment's. Writable segments are
  listed first: a segment registers with Schema when it freezes, before it leaves
  MutableSegments, so one changing state during the lookup is counted twice for a
  moment rather than missed. A writable segment that is deleted or stops before it is
  read is skipped, since its rows are gone. One that does not answer within 5 s exits
  the caller with `{:segment_unavailable, kind}`: it still holds rows queries can read,
  so its columns are not silently dropped.
  """
  def schema(table) when is_binary(table) do
    segments = MutableSegments.get_mutable_segments(table)
    {:ok, schema} = Schema.get_schema(table)

    Enum.reduce(segments, schema, fn segment, schema ->
      # As for Segment's bang readers: this runs in its callers' processes (a cluster
      # schema lookup), which must not wait on a hung segment forever.
      case Segment.schema(segment, Segment.storage_read_timeout()) do
        {:ok, schema2} ->
          Schema.merge_schemas(schema, schema2)

        {:error, {:segment_unavailable, :timeout}} ->
          Segment.exit_unavailable(:timeout)

        {:error, {:segment_unavailable, _reason}} ->
          schema
      end
    end)
  end

  @doc """
  The number of rows in `table` on this node. Expensive: asks every segment. A segment deleted or expired during the count
  is skipped, since its rows are gone. One that does not answer within 5 s, or crashes,
  exits the caller with `{:segment_unavailable, kind}`.
  """
  def table_row_count(table) when is_binary(table) do
    segment_ids(table)
    |> Enum.reduce(0, fn segment_id, count ->
      # Like the bang readers: wait at most 5 s, so a hung segment can't block a caller.
      case read_segment(segment_id, &Segment.count(&1, Segment.storage_read_timeout())) do
        {:ok, segment_count} ->
          count + segment_count

        {:error, {:segment_unavailable, reason}} ->
          if reason in [:not_found, :noproc] or Segment.normal_exit?(reason) do
            count
          else
            Segment.exit_unavailable(reason)
          end
      end
    end)
  end

  @doc """
  Merges two schemas (`%{key => Guardian.Storage.Column.Metadata}`), adding their per-type
  counts. Guardian.Cluster.Metadata merges the schemas of several machines with it.
  """
  defdelegate merge_schemas(schema1, schema2), to: Schema

  # Writable tables first, as in `schema/1`.
  def table_names do
    mutable_tables = MutableSegments.table_names()
    {:ok, frozen_tables} = Schema.get_tables()
    Enum.uniq(frozen_tables ++ mutable_tables) |> Enum.sort()
  end

  @doc """
  Storage's native resources that `:erlang.memory/0` does not count, across the VM:
  `mmap_count`, the segment-file mappings not yet unmapped, and
  `native_column_count`, the column resources not yet released. Each is an atomic
  read.
  """
  def native_counts do
    [
      mmap_count: Mmap.live_mappings(),
      native_column_count: Column.live_columns(),
    ]
  end

  def data_dir do
    Application.fetch_env!(:guardian, :data_dir)
  end

  def segment_dir do
    Path.join(data_dir(), "segments")
  end
end

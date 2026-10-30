defmodule Guardian.Storage do
  @moduledoc """
  Main storage layer interface for Guardian's custom columnar event storage.

  Storage manages the lifecycle of segments (columnar batches of ~16K events) through
  four states:

  1. **MutableSegments** - In-memory GenServer processes actively receiving writes
  2. **FullSegments** - Segments at capacity, waiting to be persisted
  3. **PersistedSegments** - Segments written to disk as .seg files
  4. **LoadedSegments** - Segments memory-mapped from disk for queries

  Operations are scoped by `table`. Guardian is single-user; there is no namespace.

  ## Public API

  This module is Storage's boundary. Code outside `lib/guardian/storage` calls only the
  functions documented here (and the data modules `Guardian.Storage.Column`,
  `Guardian.Storage.Column.Metadata`, `Guardian.Storage.Value` and `Guardian.Storage.Flattening`), names segments
  by ID, and never holds a segment's PID. The segment processes, their managers and
  `Guardian.Storage.Schema` are internal (see `lib/guardian/storage/AGENTS.md`).

  - `append/2`, `append_flattened/2`, `append_flattened_result/2` - Store a row
  - `segment_ids/1` - The IDs of a table's segments on this node
  - `segment_row_count/1`, `get_column/2` - Read a segment by ID
  - `schema/1`, `table_names/0`, `merge_schemas/2` - Inferred schemas
  - `delete_table/1`, `delete_segment/1` - Delete segments
  - `table_row_count/1`, `dump_table/1` - Expensive whole-table reads (tests)
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
  alias Guardian.Storage.FullSegments
  alias Guardian.Storage.LoadedSegments
  alias Guardian.Storage.MutableSegments
  alias Guardian.Storage.PersistedSegments
  alias Guardian.Storage.Schema
  alias Guardian.Storage.Segment
  require Guardian.SegmentID
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # On shutdown, MutableSegments hands every partial segment to FullSegments and then
  # PersistedSegments writes them all to disk, so they must stop in that order (reverse
  # child order below). The default 5 s worker shutdown can kill either mid-way and lose
  # acknowledged events, so give them more time. They must fit inside the platform's stop
  # timeout (Fly `kill_timeout`, 150 s, of which the tunnel connector's drain in
  # bin/fly-start takes up to 10 s, and 20 s at worst, before Guardian gets SIGTERM)
  # with room left for the other children. FullSegments and LoadedSegments trap exits
  # and stop their segments in `terminate/2` within the default 5 s each (about 12 ms
  # for 1,100 loaded segments), so the worst case is 110 s, leaving at least 20 s for
  # the children of Guardian.Application that stop before Storage (they normally stop at once). Past
  # its budget, a manager is killed and its links kill its segments.
  @mutable_segments_shutdown_ms 10_000
  @persisted_segments_shutdown_ms 90_000

  # Every child of Storage, in start order. `ready?/0` relies on the order: a
  # GenServer registers its name before its `init` runs, so LoadedSegments is
  # registered during its long load, but SegmentExpiration, started last, is not
  # registered until every earlier child has finished starting.
  @children [
    Schema,
    LoadedSegments,
    FullSegments,
    PersistedSegments,
    MutableSegments,
    Guardian.Storage.SegmentExpiration,
  ]

  def init(_opts) do
    children = Enum.map(@children, &child_spec_for/1)
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp child_spec_for(PersistedSegments) do
    Supervisor.child_spec(PersistedSegments, shutdown: @persisted_segments_shutdown_ms)
  end

  defp child_spec_for(MutableSegments) do
    Supervisor.child_spec(MutableSegments, shutdown: @mutable_segments_shutdown_ms)
  end

  defp child_spec_for(module) do
    module
  end

  @doc """
  Whether every Storage process is running and finished starting, and the machine has
  not begun to stop. False while Storage or one of its children restarts, including the
  segment reload after a LoadedSegments restart. Never blocks: it only looks up
  registered names, so it cannot wait on a supervisor that is busy restarting children.
  """
  def ready? do
    not Guardian.Application.stopping?() and Enum.all?(@children, &(Process.whereis(&1) != nil))
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

  def segment_ids(table) when is_binary(table) do
    # Handoffs insert the destination before removing the source. Read in that same
    # direction so a segment moving during this scan is seen in at least one state.
    [
      MutableSegments.segment_ids(table),
      FullSegments.segment_ids(table),
      PersistedSegments.segment_ids(table),
      LoadedSegments.segment_ids(table),
    ]
    |> Stream.concat()
    # |> Enum.sort()
    |> Stream.uniq()
  end

  @doc false
  def unloaded_segment_ids(table) when is_binary(table) do
    [
      MutableSegments.segment_ids(table),
      FullSegments.segment_ids(table),
      PersistedSegments.segment_ids(table),
    ]
    |> Stream.concat()
    |> Stream.uniq()
  end

  # Internal to Storage: code outside `lib/guardian/storage` names segments by ID and reads them
  # with `segment_row_count/1` and `get_column/2`, never holding a segment's PID.
  @doc false
  def get_segment(Guardian.SegmentID.match(segment_id: segment_id)) do
    with {:error, :not_found} <- LoadedSegments.get_segment(segment_id),
         {:error, :not_found} <- MutableSegments.get_segment(segment_id),
         {:error, :not_found} <- FullSegments.get_segment(segment_id),
         {:error, :not_found} <- PersistedSegments.get_segment(segment_id),
         # It may have left the persisted cache after the first loaded lookup.
         {:error, :not_found} <- LoadedSegments.get_segment(segment_id) do
      {:error, :not_found}
    end
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
      {:ok, segment} -> read_segment(segment_id, segment, read)
      {:error, :not_found} -> {:error, {:segment_unavailable, :not_found}}
    end
  end

  # Reads `segment`, which `segment_id` resolved to, retrying once on the process the
  # ID resolves to now if `segment` stopped normally or was already gone (`:noproc`)
  # and the ID has moved to a different process. That is the in-memory copy of a
  # persisted segment retired after its file was loaded (or a copy retired by a
  # delete, which then also retires the file's copy). Both copies hold the same rows
  # from the start, and every read is cut to the query's snapshot count, so the retry
  # returns what the first read would have. A crash is not retried, nor a second failure. Public only so tests can
  # pass a PID resolved before a retirement.
  @doc false
  def read_segment(segment_id, segment, read) do
    case read.(segment) do
      {:error, {:segment_unavailable, reason}} = error ->
        with true <- reason == :noproc or Segment.normal_exit?(reason),
             {:ok, other} when other != segment <- get_segment(segment_id) do
          read.(other)
        else
          _ -> error
        end

      result ->
        result
    end
  end

  def delete_table(table) do
    segment_ids(table)
    |> Enum.each(fn segment_id ->
      :ok = delete_segment(segment_id)
    end)
  end

  def delete_segment(Guardian.SegmentID.match(segment_id: segment_id)) do
    :ok = MutableSegments.delete_segment(segment_id)
    :ok = FullSegments.delete_segment(segment_id)
    :ok = PersistedSegments.delete_segment(segment_id)
    :ok = LoadedSegments.delete_segment(segment_id)
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
  The schema of `table` on this node: the loaded segments' (from `Guardian.Storage.Schema`)
  merged with each mutable segment's. A mutable segment that is deleted or stops
  between listing and reading (and has no newer copy under its ID to read instead) is
  skipped, since its rows are gone. One that does not
  answer within 5 s exits the caller with `{:segment_unavailable, kind}`: it still
  holds rows queries can read, so its columns are not silently dropped.
  """
  def schema(table) when is_binary(table) do
    {:ok, schema} = Schema.get_schema(table)

    MutableSegments.segment_ids(table)
    |> Enum.reduce(schema, fn segment_id, schema ->
      # As for Segment's bang readers: this runs in its callers' processes (a cluster
      # schema lookup), which must not wait on a hung segment forever.
      case read_segment(segment_id, &Segment.schema(&1, Segment.storage_read_timeout())) do
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
  The number of rows in `table` on this node. Expensive: asks every segment, loaded or
  not. Each segment ID counts once, even while a segment is both cached after
  persisting and loaded from its file. A segment deleted or expired during the count
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

  def table_names do
    {:ok, persisted_tables} = Schema.get_tables()
    mutable_tables = MutableSegments.table_names()
    Enum.uniq(persisted_tables ++ mutable_tables) |> Enum.sort()
  end

  def data_dir do
    Application.fetch_env!(:guardian, :data_dir)
  end

  def segment_dir do
    Path.join(data_dir(), "segments")
  end
end

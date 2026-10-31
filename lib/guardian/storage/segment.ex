defmodule Guardian.Storage.Segment do
  # Internal to Storage; see lib/guardian/storage/AGENTS.md, "Public boundary".
  @moduledoc false

  alias Guardian.Storage.Column
  alias Guardian.Storage.Schema
  alias Guardian.Storage.SegmentFile
  alias Guardian.Storage.Value

  # Every segment runs under Guardian.Storage's SegmentSupervisor, a DynamicSupervisor
  # that stops its children concurrently at shutdown. A crashed segment stays dead. The
  # budget is for writing a segment's file in `terminate` (see there).
  use GenServer, restart: :temporary, shutdown: 90_000

  # Exit reasons of a GenServer call to a segment that is gone rather than one that
  # crashed while handling the call.
  @dead_reasons [:noproc, :normal, :shutdown, :killed, :noconnection]

  @default_max_bytes 64 * 1024 * 1024

  # A segment is one process for its whole life: writable, then frozen (`capacity`
  # equals `count`; its final count and schema are registered with Schema), then
  # persisted (its file is written and its columns are sub-binaries of the mapped
  # file). `segment_id` and `table` name its file and its Schema entry; a bare segment
  # in a unit test may have neither, and then never registers or writes.
  #
  # `value_bytes` maps each key to its column's packed size beyond that of a column of
  # nils (`Column.nil_column_size/1`), and `total_value_bytes` sums them. Only
  # appended rows maintain them.
  #
  # A mutable column is a NIF resource whose native buffers `append` grows in place.
  # Only this process ever touches one (column.c has no locks). Readers get
  # `snapshots`: packed copies of mutable columns padded to the current `count`, made
  # here and kept until the row count changes.
  #
  # `segment_id` and `table` come first so that a crash report, which prints the state
  # truncated, names the segment before its columns.
  @enforce_keys [:count, :capacity, :columns]
  defstruct [
    :segment_id,
    :table,
    :count,
    :capacity,
    :columns,
    frozen: false,
    persisted: false,
    max_bytes: :infinity,
    value_bytes: %{},
    total_value_bytes: 0,
    max_age_ms: :infinity,
    max_age_owner: nil,
    age_timer: nil,
    snapshots: %{},
  ]

  @doc """
  Starts a segment, linked to the caller (SegmentSupervisor, through
  `start_supervised/1`, for Storage's segments).

  Options:

    * `:segment_id`, `:table` - the segment's ID and table, which name its file and its
      Schema entry. Without them it never registers its schema or writes a file.
    * `:capacity` - rows the segment holds before it is full (default 16384).
    * `:max_bytes` - byte budget (default 64 MiB, or `:infinity`). The segment is also
      full once the packed size of its columns, padded to its row count, reaches the
      budget. See `append/2`.
    * `:load` - a segment file to load instead of starting empty. A file that cannot
      be loaded (truncated, empty, malformed header, unmappable) stops the segment in
      `init` with `{:shutdown, {:unreadable_segment, reason}}`, so no crash report
      carries the file's bytes.
    * `:max_age_ms` - freeze after this many milliseconds from the first stored row
      (default `:infinity`). Empty segments have no age timer.
    * `:max_age_owner` - process notified with `{:segment_max_age, segment}` when
      the age timer freezes a nonempty segment.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Starts a segment (`start_link/1`'s options) under SegmentSupervisor.
  """
  def start_supervised(opts) do
    DynamicSupervisor.start_child(Guardian.Storage.SegmentSupervisor, {__MODULE__, opts})
  end

  @doc """
  Asks the segment to persist itself, without waiting: it freezes, packs its columns,
  writes its file, maps the file back and serves from the mapping from then on. A
  failed write, or a file that won't map, crashes the segment. A segment already
  persisted, or without rows, does nothing. Messages from one sender arrive in order,
  so a caller's later call to the segment returns after the persist has finished.
  """
  def persist(segment) when is_pid(segment) do
    GenServer.cast(segment, :persist)
  end

  @doc """
  Stops a segment and returns once its process is gone, however it died. Safe when the
  segment has already exited or exits concurrently (a bare `GenServer.stop/3` would
  exit the caller with `:noproc` or the competing reason). A registry that monitors the
  segment still receives its `:DOWN` afterward and must ignore it. It stops the segment
  with `:normal`, so `terminate` writes no file: a deleted segment stays deleted.
  """
  def retire(segment) when is_pid(segment) do
    ref = Process.monitor(segment)

    try do
      GenServer.stop(segment, :normal, :infinity)
    catch
      # Already gone, which is what this call wants.
      :exit, _reason -> :ok
    end

    receive do
      {:DOWN, ^ref, :process, ^segment, _reason} -> :ok
    end
  end

  @doc "Whether a segment's exit reason is a deliberate stop rather than a crash."
  def normal_exit?(reason) when reason in [:normal, :shutdown] do
    true
  end

  def normal_exit?({:shutdown, _}) do
    true
  end

  def normal_exit?(_reason) do
    false
  end

  # Reads (count, full, keys, schema, get_column) are monitored
  # calls with no timeout by default, so a slow segment is waited for, and a segment
  # that is gone or dies mid-call (including a remote one whose node disconnects)
  # returns `{:error, {:segment_unavailable, reason}}` at once. Queries rely on this
  # to fail cleanly instead of crashing or hanging. Storage's own callers
  # use the bang readers below instead, so a segment that hangs or dies crashes them
  # as it always did instead of blocking them. A reply that arrives after a timeout is
  # dropped.
  @type read_error :: {:error, {:segment_unavailable, term()}}

  # The bang readers are for Storage's own callers: they wait at most 5 s, and a
  # failed read exits with only the reason's kind (`Guardian.Failure.exit_kind/1`),
  # because the crash report must not carry the segment's rows.
  # `Guardian.Storage.schema/1` uses the same budget and exit.
  @storage_read_timeout 5_000

  @doc "How long Storage's own callers wait on a segment read: 5 s."
  def storage_read_timeout do
    @storage_read_timeout
  end

  @doc """
  Exits for a failed read with `{:segment_unavailable, kind}`, naming only the
  reason's kind (`Guardian.Failure.exit_kind/1`) so the exit carries none of the
  segment's rows.
  """
  @spec exit_unavailable(term()) :: no_return()
  def exit_unavailable(reason) do
    exit({:segment_unavailable, Guardian.Failure.exit_kind(reason)})
  end

  @doc "`count/2` for Storage's own callers: 5 s, and exits on failure."
  def count!(segment) do
    ok!(count(segment, @storage_read_timeout))
  end

  @doc "`keys/2` for Storage's own callers: 5 s, and exits on failure."
  def keys!(segment) do
    ok!(keys(segment, @storage_read_timeout))
  end

  @doc "`get_column/3` for Storage's own callers: 5 s, and exits on failure."
  def get_column!(segment, key) do
    ok!(get_column(segment, key, @storage_read_timeout))
  end

  defp ok!({:ok, value}) do
    value
  end

  defp ok!({:error, {:segment_unavailable, reason}}) do
    exit_unavailable(reason)
  end

  @spec count(pid(), timeout()) :: {:ok, non_neg_integer()} | read_error()
  def count(segment, timeout \\ :infinity) do
    read(segment, :count, timeout)
  end

  @spec full(pid(), timeout()) :: {:ok, boolean()} | read_error()
  def full(segment, timeout \\ :infinity) do
    read(segment, :full, timeout)
  end

  defp read(segment, message, timeout) do
    GenServer.call(segment, message, timeout)
  catch
    # A segment can go at any moment, by expiry or deletion: an outcome for callers.
    :exit, {reason, {GenServer, :call, _}} -> {:error, {:segment_unavailable, reason}}
  end

  @doc """
  Appends a row, already flattened into dot-notation keys (`Guardian.Storage.append/2`
  flattens), to the segment atomically.

  Returns `:ok` when the row is stored and the segment has room for more, and
  `{:ok, :full}` when the row is stored and filled the segment: it now holds
  `capacity` rows, or the packed size of its columns reached `max_bytes`. The byte
  budget is soft: the row that crosses it is stored whole, however large.

  Returns `{:error, :full}` when the segment is already full, and
  `{:error, :invalid_value}` when the segment refuses a value no column can hold.
  Returns `{:error, :dead}` if the segment process is not alive or dies during the
  call, so the caller can retry elsewhere. Before calling, it raises in the caller
  for a key or value Storage rejects: `ArgumentError` for an over-long key,
  `FunctionClauseError` for a key that is not an atom or string, and `MatchError` for
  a value `Guardian.Storage.Value` rejects. Exceptions and exits from the call itself
  propagate; those may occur after the row was stored.
  """
  @spec append(pid(), map()) ::
          :ok | {:ok, :full} | {:error, :full | :dead | :invalid_value}
  def append(segment, flat_row) when is_pid(segment) do
    row =
      Map.new(flat_row, fn {key, value} ->
        {validate_key(key), Value.validate(value)}
      end)

    # A monitored call, so that a segment that is gone is reported instead of waiting
    # out the timeout. Other exits propagate: a timeout because the segment may have
    # stored the row, so retrying could store it twice, and a crash because retrying
    # the same row could crash the next segment too.
    try do
      GenServer.call(segment, {:append, row})
    catch
      :exit, {reason, {GenServer, :call, _}} when reason in @dead_reasons ->
        {:error, :dead}

      :exit, {{:shutdown, _}, {GenServer, :call, _}} ->
        {:error, :dead}
    end
  end

  defp validate_key(key) when is_atom(key) do
    Atom.to_string(key)
    |> validate_key()
  end

  defp validate_key(key) when is_binary(key) do
    if Value.valid_key?(key) do
      key
    else
      raise ArgumentError, "key is longer than #{Value.max_key_size()} bytes"
    end
  end

  @spec keys(pid(), timeout()) :: {:ok, [String.t()]} | read_error()
  def keys(segment, timeout \\ :infinity) do
    read(segment, :keys, timeout)
  end

  @spec schema(pid(), timeout()) :: {:ok, map()} | read_error()
  def schema(segment, timeout \\ :infinity) do
    read(segment, :schema, timeout)
  end

  @doc """
  Returns the column for `key` as a packed binary holding at least `count` rows. For a
  mutable segment it is a snapshot that later appends don't change.
  `{:error, :not_found}` means the segment has no such column.
  """
  @spec get_column(pid(), String.t(), timeout()) ::
          {:ok, binary()} | {:error, :not_found} | read_error()
  def get_column(segment, key, timeout \\ :infinity) when is_binary(key) do
    read(segment, {:get_column, key}, timeout)
  end

  def init(opts) do
    # A trapped exit from SegmentSupervisor at shutdown runs `terminate`, which writes
    # the file of a segment not yet persisted.
    Process.flag(:trap_exit, true)
    segment_id = Keyword.get(opts, :segment_id)
    table = Keyword.get(opts, :table)

    case Keyword.fetch(opts, :load) do
      :error ->
        state = %__MODULE__{
          count: 0,
          capacity: Keyword.get(opts, :capacity, 16 * 1024),
          columns: %{},
          segment_id: segment_id,
          table: table,
          max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
          max_age_ms: Keyword.get(opts, :max_age_ms, :infinity),
          max_age_owner: Keyword.get(opts, :max_age_owner),
        }

        unless state.max_age_ms == :infinity or
                 (is_integer(state.max_age_ms) and state.max_age_ms > 0) do
          raise ArgumentError, "max_age_ms must be a positive integer or :infinity"
        end

        {:ok, state}

      {:ok, filename} ->
        case SegmentFile.read(filename) do
          {:ok, count, columns} ->
            state = %__MODULE__{
              count: count,
              capacity: count,
              columns: columns,
              segment_id: segment_id,
              table: table,
              persisted: true,
            }

            {:ok, freeze_state(state)}

          # `:shutdown` keeps proc_lib from logging a crash report, whose stack
          # trace would carry the file's bytes as call arguments.
          {:error, reason} ->
            {:stop, {:shutdown, {:unreadable_segment, reason}}}
        end
    end
  end

  def handle_call(:count, _, state) do
    {:reply, {:ok, state.count}, state}
  end

  def handle_call(:full, _, state) do
    cond do
      state.count < state.capacity ->
        {:reply, {:ok, false}, state}

      state.count == state.capacity ->
        {:reply, {:ok, true}, state}
    end
  end

  def handle_call({:append, row}, _, state) do
    cond do
      state.count >= state.capacity ->
        {:reply, {:error, :full}, state}

      # Check every value before changing any column, so a row is stored completely or
      # not at all. Columns have no size caps, so any column accepts a valid value.
      not Enum.all?(row, fn {_key, value} -> Column.valid_value?(value) end) ->
        {:reply, {:error, :invalid_value}, state}

      true ->
        state = append_row(state, row)

        if state.count >= state.capacity or over_budget?(state) do
          # Stop accepting rows, exactly as if the row count were reached.
          {:reply, {:ok, :full}, freeze_state(state)}
        else
          {:reply, :ok, start_age_timer(state)}
        end
    end
  end

  def handle_call(:keys, _, state) do
    keys = Map.keys(state.columns)
    {:reply, {:ok, keys}, state}
  end

  def handle_call(:schema, _, state) do
    schema =
      Map.new(state.columns, fn {key, column} ->
        {key, Column.metadata(column)}
      end)

    {:reply, {:ok, schema}, state}
  end

  def handle_call({:get_column, key}, _, state) do
    case state.columns do
      %{^key => column} when is_binary(column) ->
        {:reply, {:ok, column}, state}

      %{^key => _column} ->
        {snapshot, state} = snapshot(state, key)
        {:reply, {:ok, snapshot}, state}

      %{} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # Freezes, packs, writes, maps and swaps in one message: reads and appends queued
  # behind it wait (tens of milliseconds for a full segment), and appends then get
  # `{:error, :full}` and retry elsewhere. Hibernating is a full-sweep garbage
  # collection, which releases the native and packed columns the mapped ones replaced;
  # an idle process would otherwise hold them until its next collection.
  def handle_cast(:persist, state) do
    state = freeze_state(state)

    if not unwritten_rows?(state) do
      {:noreply, state}
    else
      filename = write_file(state)
      # A file that won't map crashes the segment; it stays on disk for the next start.
      {:ok, count, columns} = SegmentFile.read(filename)
      ^count = state.count
      state = %{state | columns: columns, snapshots: %{}, persisted: true}
      {:noreply, state, :hibernate}
    end
  end

  def handle_info(:max_age, state) do
    if state.count > 0 and state.count < state.capacity do
      state = freeze_state(state)

      if state.max_age_owner do
        send(state.max_age_owner, {:segment_max_age, self()})
      end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp start_age_timer(%{count: 1, max_age_ms: max_age_ms, age_timer: nil} = state)
       when is_integer(max_age_ms) do
    %{state | age_timer: Process.send_after(self(), :max_age, max_age_ms)}
  end

  defp start_age_timer(state) do
    state
  end

  # The packed snapshot of the mutable column `key`, padded to the row count.
  defp snapshot(state, key) do
    case state.snapshots do
      %{^key => snapshot} ->
        {snapshot, state}

      %{} ->
        snapshot = state.columns[key] |> Column.pad(state.count) |> Column.pack()
        {snapshot, put_in(state.snapshots[key], snapshot)}
    end
  end

  defp freeze_state(%{frozen: true} = state) do
    state
  end

  # Stops accepting rows and, the first time, registers the final count and schema with
  # Schema: before the segment can leave MutableSegments, so a schema read counts it
  # twice rather than missing it. Columns are padded to the row count first, so the
  # schema counts the nils of rows that lacked a key, as the file will.
  defp freeze_state(state) do
    if state.age_timer, do: Process.cancel_timer(state.age_timer)
    state = %{state | capacity: state.count, age_timer: nil, frozen: true}

    if state.table != nil and state.count > 0 do
      schema =
        Map.new(state.columns, fn {key, column} ->
          {key, column |> pad_column(state.count) |> Column.metadata()}
        end)

      :ok = Schema.add_segment(self(), state.table, state.count, schema)
    end

    state
  end

  defp pad_column(column, _count) when is_binary(column) do
    column
  end

  defp pad_column(column, count) do
    Column.pad(column, count)
  end

  # Whether the segment has rows not yet in its file, and a file to write them to.
  defp unwritten_rows?(state) do
    state.table != nil and not state.persisted and state.count > 0
  end

  # Writes the segment's columns, packed and padded to the row count (reusing cached
  # snapshots), to its file, crashing the segment if the write fails.
  defp write_file(state) do
    {keys, columns} =
      state.columns
      |> Enum.map(fn
        {key, column} when is_binary(column) -> {key, column}
        {key, _column} -> {key, state |> snapshot(key) |> elem(0)}
      end)
      |> Enum.unzip()

    filename = SegmentFile.filename(state.table, state.segment_id)
    :ok = SegmentFile.write(filename, state.count, keys, columns)
    filename
  end

  # Writes the file of a segment that has rows and isn't persisted yet, when Storage
  # stops (SegmentSupervisor's `:shutdown`, at a normal stop or a restart of its
  # group). Never on `:normal`, which deletion uses, or on a crash, whose columns may
  # be half-appended. A segment busy persisting finishes that first, and then has
  # nothing to write.
  def terminate(reason, state) do
    if (reason == :shutdown or match?({:shutdown, _}, reason)) and unwritten_rows?(state) do
      write_file(state)
    end
  end

  defp append_row(state, row) do
    count = state.count
    nil_column_size = Column.nil_column_size(count + 1)

    state =
      Enum.reduce(row, state, fn {key, value}, state when is_binary(key) ->
        # A new column starts empty and grows as it is padded and appended to, so a
        # key that appears in few rows holds little memory.
        {column, state} =
          case state.columns do
            %{^key => column} ->
              {column, state}

            %{} ->
              column = Column.new(0)
              {column, put_in(state.columns[key], column)}
          end

        # Padding only adds rows below capacity.
        :ok =
          column
          |> Column.pad(count)
          |> Column.append(value)

        value_bytes = Column.packed_size(column) - nil_column_size
        old_value_bytes = Map.get(state.value_bytes, key, 0)

        %{
          state
          | value_bytes: Map.put(state.value_bytes, key, value_bytes),
            total_value_bytes: state.total_value_bytes + value_bytes - old_value_bytes,
        }
      end)

    # Every snapshot was padded to the old count.
    %{state | count: count + 1, snapshots: %{}}
  end

  # The packed size of every column once padded to the row count: what the segment's
  # columns will take when packed and stored.
  defp packed_bytes(state) do
    state.total_value_bytes + map_size(state.columns) * Column.nil_column_size(state.count)
  end

  defp over_budget?(%{max_bytes: :infinity}) do
    false
  end

  defp over_budget?(state) do
    packed_bytes(state) >= state.max_bytes
  end
end

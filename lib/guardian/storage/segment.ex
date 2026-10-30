defmodule Guardian.Storage.Segment do
  # Internal to Storage; see lib/guardian/storage/AGENTS.md, "Public boundary".
  @moduledoc false

  alias Guardian.Storage.Column
  alias Guardian.Storage.SegmentFile
  alias Guardian.Storage.Value

  # Exit reasons of a GenServer call to a segment that is gone rather than one that
  # crashed while handling the call.
  @dead_reasons [:noproc, :normal, :shutdown, :killed, :noconnection]

  @default_max_bytes 64 * 1024 * 1024

  # `value_bytes` maps each key to its column's packed size beyond that of a column of
  # nils (`Column.nil_column_size/1`), and `total_value_bytes` sums them. Only
  # appended rows maintain them.
  #
  # A mutable column is a NIF resource whose native buffers `append` grows in place.
  # Only this process ever touches one (column.c has no locks). Readers get
  # `snapshots`: packed copies of mutable columns padded to the current `count`, made
  # here and kept until the row count changes.
  @enforce_keys [:count, :capacity, :columns]
  defstruct [
    :count,
    :capacity,
    :columns,
    max_bytes: :infinity,
    value_bytes: %{},
    total_value_bytes: 0,
    max_age_ms: :infinity,
    max_age_owner: nil,
    age_timer: nil,
    snapshots: %{},
  ]

  @doc """
  Starts a segment.

  Options:

    * `:capacity` - rows the segment holds before it is full (default 16384).
    * `:max_bytes` - byte budget (default 64 MiB, or `:infinity`). The segment is also
      full once the packed size of its columns, padded to its row count, reaches the
      budget. See `append/2`.
    * `:load` - a segment file to load instead of starting empty.
    * `:max_age_ms` - freeze after this many milliseconds from the first stored row
      (default `:infinity`). Empty segments have no age timer.
    * `:max_age_owner` - process notified with `{:segment_max_age, segment}` when
      the age timer freezes a nonempty segment.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, opts)
  end

  @doc """
  Starts a segment from a segment file, linked to the caller only if the file loads.
  Returns `{:ok, pid}`, or `{:error, {:unreadable_segment, reason}}` for a file that
  cannot be loaded (truncated, empty, malformed header, unmappable), without affecting
  the caller. The segment links itself to the caller at the end of a successful
  `init`, so there is no moment when a loaded segment outlives a dead caller.
  """
  def load(filename) do
    case GenServer.start(__MODULE__, load: filename, owner: self()) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:shutdown, {:unreadable_segment, _} = reason}} -> {:error, reason}
      {:error, reason} -> {:error, {:unreadable_segment, reason}}
    end
  end

  @doc """
  Stops a segment and returns once its process is gone, however it died. Safe when the
  segment has already exited or exits concurrently (a bare `GenServer.stop/3` would
  exit the caller with `:noproc` or the competing reason). A manager that links the
  segment still receives its `{:EXIT, ...}` afterward and must ignore it.
  """
  def retire(segment) when is_pid(segment) do
    ref = Process.monitor(segment)

    try do
      GenServer.stop(segment, :normal, :infinity)
    catch
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
  # to fail cleanly instead of crashing or hanging. Storage's own processes
  # use the bang readers below instead, so a segment that hangs or dies crashes them
  # as it always did instead of blocking them. A reply that arrives after a timeout is
  # dropped.
  @type read_error :: {:error, {:segment_unavailable, term()}}

  # The bang readers are for Storage's own processes: they wait at most 5 s, and a
  # failed read exits with only the reason's kind (`Guardian.Failure.exit_kind/1`),
  # because the crash report must not carry the segment's rows.
  # `Guardian.Storage.schema/1` uses the same budget and exit.
  @storage_read_timeout 5_000

  @doc "How long Storage's own processes wait on a segment read: 5 s."
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

  @doc "`count/2` for Storage's own processes: 5 s, and exits on failure."
  def count!(segment) do
    ok!(count(segment, @storage_read_timeout))
  end

  @doc "`full/2` for Storage's own processes: 5 s, and exits on failure."
  def full!(segment) do
    ok!(full(segment, @storage_read_timeout))
  end

  @doc "`keys/2` for Storage's own processes: 5 s, and exits on failure."
  def keys!(segment) do
    ok!(keys(segment, @storage_read_timeout))
  end

  @doc "`schema/2` for Storage's own processes: 5 s, and exits on failure."
  def schema!(segment) do
    ok!(schema(segment, @storage_read_timeout))
  end

  @doc "`get_column/3` for Storage's own processes: 5 s, and exits on failure."
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

  # Calls for Storage's writers (freeze, packing, storing). Unlike the readers they
  # exit on failure: a segment that is gone exits at once, one that dies mid-call exits
  # with its reason, and one stuck past 5 s exits with `:timeout`. GenServer.call
  # monitors the segment and drops a reply that arrives after the timeout.
  defp write_call(segment, message) do
    GenServer.call(segment, message, 5_000)
  end

  def freeze(segment) do
    write_call(segment, :freeze)
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
  Stores a packed column under `key`. Only packed (binary) columns are accepted: a
  mutable column kept by the caller could be changed behind the segment's back.
  """
  def put_column(segment, key, column) when is_binary(key) and is_binary(column) do
    write_call(segment, {:put_column, key, column})
  end

  def update_count(segment, count) when is_integer(count) do
    write_call(segment, {:update_count, count})
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

  @doc """
  Freezes the segment and packs its columns. The segment packs one column per call, so
  reads interleave with packing.
  """
  def pack(segment) do
    # Writer side: 5 s calls that exit when the segment is dead, dies, or is stuck,
    # which the persister handles.
    :ok = freeze(segment)
    {:ok, keys} = write_call(segment, :keys)

    Enum.each(keys, fn key ->
      :ok = write_call(segment, {:pack_column, key})
    end)
  end

  @doc """
  Writes a frozen, packed segment to `filename` (`Guardian.Storage.SegmentFile.write/4`).
  """
  def store(segment, filename) do
    {:ok, true} = write_call(segment, :full)

    case write_call(segment, :packed_columns) do
      {:ok, count, keys, columns} -> SegmentFile.write(filename, count, keys, columns)
      {:error, :not_packed} -> raise RuntimeError, "Column not packed"
    end
  end

  def init(opts) do
    case Keyword.fetch(opts, :load) do
      :error ->
        state = %__MODULE__{
          count: 0,
          capacity: Keyword.get(opts, :capacity, 16 * 1024),
          columns: %{},
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
            # A dead owner makes this exit with :noproc, so the segment cannot leak.
            if owner = opts[:owner], do: Process.link(owner)
            {:ok, %__MODULE__{count: count, capacity: count, columns: columns}}

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

  def handle_call(:freeze, _, state) do
    {:reply, :ok, freeze_state(state)}
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

  def handle_call({:put_column, key, column}, _, state) when is_binary(column) do
    state = put_in(state.columns[key], column)
    {:reply, :ok, drop_snapshot(state, key)}
  end

  def handle_call({:put_column, _key, _column}, _, state) do
    {:reply, {:error, :not_binary}, state}
  end

  def handle_call({:update_count, new_count}, _, state) do
    state =
      update_in(state.count, fn
        old_count when old_count <= new_count -> new_count
      end)

    {:reply, :ok, %{state | snapshots: %{}}}
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

  # Replaces a frozen segment's mutable column with its packed form, reusing the
  # snapshot when there is one, so the segment never holds two packed copies.
  def handle_call({:pack_column, key}, _, state) do
    cond do
      state.count != state.capacity ->
        {:reply, {:error, :not_frozen}, state}

      not Map.has_key?(state.columns, key) ->
        {:reply, {:error, :not_found}, state}

      is_binary(state.columns[key]) ->
        {:reply, :ok, state}

      true ->
        {packed, state} = snapshot(state, key)
        state = put_in(state.columns[key], packed)
        {:reply, :ok, drop_snapshot(state, key)}
    end
  end

  def handle_call(:packed_columns, _, state) do
    {keys, columns} = Enum.unzip(state.columns)

    if Enum.all?(columns, &is_binary/1) do
      {:reply, {:ok, state.count, keys, columns}, state}
    else
      {:reply, {:error, :not_packed}, state}
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

  defp drop_snapshot(state, key) do
    %{state | snapshots: Map.delete(state.snapshots, key)}
  end

  defp freeze_state(state) do
    if state.age_timer, do: Process.cancel_timer(state.age_timer)
    %{state | capacity: state.count, age_timer: nil}
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

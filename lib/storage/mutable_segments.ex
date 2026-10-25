defmodule Guardian.Storage.MutableSegments do
  # Internal to Storage; see lib/storage/CLAUDE.md, "Public boundary".
  @moduledoc false

  alias Guardian.Storage.FullSegments
  alias Guardian.Storage.PersistedSegments
  alias Guardian.Storage.Segment
  alias Guardian.Storage.Segment.Registration
  require Registration
  require Logger
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def segment_ids(table), do: Registration.segment_ids(__MODULE__, table)

  def table_names do
    :ets.select(__MODULE__, Registration.match_spec(select: :table))
    |> Enum.uniq()
  end

  def get_segment(segment_id), do: Registration.lookup(__MODULE__, segment_id)

  def delete_segment(segment_id) do
    GenServer.call(__MODULE__, {:delete_segment, segment_id})
  end

  def get_mutable_segments(table) do
    :ets.select(
      __MODULE__,
      Registration.match_spec(table: table, select: :segment)
    )
  end

  def segment_is_full(table, segment) do
    GenServer.call(__MODULE__, {:segment_is_full, table, segment})
  end

  def segment_died(segment) do
    GenServer.call(__MODULE__, {:segment_died, segment})
  end

  def ensure_at_least_n_mutable_segments(table, n) do
    GenServer.call(__MODULE__, {:ensure_at_least_n_mutable_segments, table, n})
  end

  @doc """
  Appends a row already flattened into dot-notation keys to one of `table`'s mutable
  segments, retrying in another when a segment is full or gone. Returns explicit
  segment refusals; `Guardian.Storage` holds the flattening and raising wrappers.
  """
  @spec append(String.t(), map()) :: :ok | {:error, :invalid_value}
  def append(table, flat_row) do
    segments = get_mutable_segments(table)

    case choose_best_segment(segments) do
      {:error, :not_found} ->
        :ok = ensure_at_least_n_mutable_segments(table, length(segments) + 1)
        append(table, flat_row)

      {:ok, segment} ->
        case Segment.append(segment, flat_row) do
          {:error, :full} ->
            :ok = segment_is_full(table, segment)
            append(table, flat_row)

          {:error, :dead} ->
            :ok = segment_died(segment)
            append(table, flat_row)

          :ok ->
            :ok

          # The row filled the segment. Hand it off for persistence now rather than
          # when the next row arrives, which on a quiet table may be much later.
          {:ok, :full} ->
            :ok = segment_is_full(table, segment)
            :ok

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp choose_best_segment(segments) do
    segments
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.take_random(2)
    |> case do
      [] ->
        {:error, :not_found}

      [{segment, 0}] ->
        {:ok, segment}

      [{segment1, offset1}, {segment2, offset2}] ->
        case Process.info(segment1, :message_queue_len) do
          nil ->
            case Process.alive?(segment2) do
              true -> {:ok, segment2}
              false -> {:error, :not_found}
            end

          {:message_queue_len, load1} ->
            case Process.info(segment2, :message_queue_len) do
              nil ->
                {:ok, segment1}

              {:message_queue_len, load2} ->
                if load1 - offset1 < load2 - offset2 do
                  {:ok, segment1}
                else
                  {:ok, segment2}
                end
            end
        end
    end
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    :ets.new(__MODULE__, [:named_table, :ordered_set])

    max_age_ms =
      Keyword.get(
        opts,
        :max_age_ms,
        Application.get_env(:guardian, :mutable_segment_max_age_ms, 3_600_000)
      )

    unless is_integer(max_age_ms) and max_age_ms > 0 do
      raise ArgumentError, "mutable_segment_max_age_ms must be a positive integer"
    end

    state = %{max_age_ms: max_age_ms}
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ets.tab2list(__MODULE__)
    |> Enum.each(fn registration ->
      :ok = FullSegments.insert(registration)
      segment = Registration.segment(registration)
      true = Process.unlink(segment)
    end)
  end

  def handle_call({:delete_segment, segment_id}, _, state) do
    :ok = Registration.retire_segment_id(__MODULE__, segment_id)
    {:reply, :ok, state}
  end

  def handle_call({:segment_is_full, table, segment}, _, state) do
    :ets.select(
      __MODULE__,
      Registration.match_spec(segment: segment, table: table)
    )
    |> Enum.each(&handoff/1)

    {:reply, :ok, state}
  end

  def handle_call({:segment_died, segment}, _, state) do
    # An append found it gone, without its exit reason.
    :ok = unregister_dead_segment(segment, :noproc)
    {:reply, :ok, state}
  end

  def handle_call({:ensure_at_least_n_mutable_segments, table, count}, _, state) do
    num_mutable_segments = get_mutable_segments(table) |> length()
    num_segments_to_create = max(0, count - num_mutable_segments)
    :ok = create_segments(table, num_segments_to_create, state.max_age_ms)
    true = get_mutable_segments(table) |> length() >= count
    {:reply, :ok, state}
  end

  defp create_segments(table, count, max_age_ms) when count > 0 do
    {:ok, segment} = Segment.start_link(max_age_ms: max_age_ms, max_age_owner: self())
    segment_id = Guardian.SegmentID.generate()

    true =
      :ets.insert(
        __MODULE__,
        Registration.tuple(
          segment_id: segment_id,
          segment: segment,
          table: table
        )
      )

    create_segments(table, count - 1, max_age_ms)
  end

  defp create_segments(_table, 0, _max_age_ms) do
    :ok
  end

  def handle_info({:segment_max_age, segment}, state) do
    :ets.select(__MODULE__, Registration.match_spec(segment: segment))
    |> Enum.each(&handoff/1)

    {:noreply, state}
  end

  # Mutable segments are linked to this process, which traps exits. Matches by PID: a
  # late EXIT from a segment this manager no longer holds (deleted, or handed to
  # FullSegments) finds nothing and is ignored.
  def handle_info({:EXIT, segment, reason}, state) do
    :ok = unregister_dead_segment(segment, reason)
    {:noreply, state}
  end

  defp handoff(registration) do
    segment = Registration.segment(registration)
    :ok = FullSegments.insert(registration)
    true = :ets.delete_object(__MODULE__, registration)
    true = Process.unlink(segment)
    :ok = PersistedSegments.ping()
  end

  defp unregister_dead_segment(segment, reason) do
    Registration.unregister_exited(__MODULE__, segment)
    |> Enum.each(fn Registration.tuple(segment_id: segment_id, table: table) ->
      Logger.error(
        "Dropping dead mutable segment #{segment_id} of table #{inspect(table)} " <>
          "(#{Segment.exit_kind(reason)}); its rows are lost"
      )
    end)
  end
end

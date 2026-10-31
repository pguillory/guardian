defmodule Guardian.Storage.MutableSegments do
  # Internal to Storage; see lib/guardian/storage/AGENTS.md, "Public boundary".
  @moduledoc false

  # The registry of writable segments, and the segment lifecycle: it creates each
  # segment under SegmentSupervisor and registers it in ReadableSegments and here, and
  # when one is full or reaches its maximum age it deregisters it and tells it to
  # persist; the segment does the rest. It monitors its segments rather than linking
  # them, so a segment that dies drops out. At shutdown it does nothing: each segment
  # writes its own file (`Guardian.Storage.Segment.terminate/2`).

  alias Guardian.Storage.ReadableSegments
  alias Guardian.Storage.Segment
  alias Guardian.Storage.Segment.Registration
  require Registration
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def segment_ids(table) do
    Registration.segment_ids(__MODULE__, table)
  end

  def table_names do
    :ets.select(__MODULE__, Registration.match_spec(select: :table))
    |> Enum.uniq()
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

          # The row filled the segment. Persist it now rather than
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

  def handle_call({:segment_is_full, table, segment}, _, state) do
    :ets.select(
      __MODULE__,
      Registration.match_spec(segment: segment, table: table)
    )
    |> Enum.each(&persist/1)

    {:reply, :ok, state}
  end

  def handle_call({:segment_died, segment}, _, state) do
    # An append found it gone, without its exit reason.
    :ok = Registration.unregister(__MODULE__, segment)
    {:reply, :ok, state}
  end

  def handle_call({:ensure_at_least_n_mutable_segments, table, count}, _, state) do
    num_mutable_segments = get_mutable_segments(table) |> length()
    num_segments_to_create = max(0, count - num_mutable_segments)
    :ok = create_segments(table, num_segments_to_create, state.max_age_ms)
    true = get_mutable_segments(table) |> length() >= count
    {:reply, :ok, state}
  end

  # Registered in ReadableSegments first: an appender can use the segment as soon as it
  # is in this table, and its rows must be readable once the append returns.
  defp create_segments(table, count, max_age_ms) when count > 0 do
    segment_id = Guardian.SegmentID.generate()

    {:ok, segment} =
      Segment.start_supervised(
        segment_id: segment_id,
        table: table,
        max_age_ms: max_age_ms,
        max_age_owner: self()
      )

    registration = Registration.tuple(segment_id: segment_id, segment: segment, table: table)
    :ok = ReadableSegments.insert(registration)
    :ok = Registration.register(__MODULE__, registration)
    create_segments(table, count - 1, max_age_ms)
  end

  defp create_segments(_table, 0, _max_age_ms) do
    :ok
  end

  def handle_info({:segment_max_age, segment}, state) do
    :ets.select(__MODULE__, Registration.match_spec(segment: segment))
    |> Enum.each(&persist/1)

    {:noreply, state}
  end

  # Matches by PID: a late DOWN from a segment already persisting finds nothing.
  def handle_info({:DOWN, _ref, :process, segment, _reason}, state) do
    :ok = Registration.unregister(__MODULE__, segment)
    {:noreply, state}
  end

  # Readers may still hold its PID; it stays in ReadableSegments.
  defp persist(registration) do
    true = :ets.delete_object(__MODULE__, registration)
    :ok = Segment.persist(Registration.segment(registration))
  end
end

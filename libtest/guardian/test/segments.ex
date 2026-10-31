defmodule Guardian.Test.Segments do
  @moduledoc """
  Builds segment fixtures and injects append failures. Tests must isolate their
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
  Writes a segment file holding flat `rows` to `filename`, through a temporary
  in-memory segment (appended, packed, stored, stopped), and returns `filename`. The
  caller removes the file.
  """
  def write_segment_file(filename, rows) do
    {:ok, segment} = Guardian.Storage.Segment.start_link()
    Enum.each(rows, &(:ok = Guardian.Storage.Segment.append(segment, &1)))
    :ok = Guardian.Storage.Segment.pack(segment)
    :ok = Guardian.Storage.Segment.store(segment, filename)
    GenServer.stop(segment)
    filename
  end

  @doc """
  Waits until every full segment of `table` has been written to disk and at least one
  is loaded from its file, asking for the write and a rescan as it polls. For Storage
  and query tests that need rows on disk.
  """
  def await_persisted(table) do
    Guardian.Test.Polling.eventually(
      fn ->
        :ok = Guardian.Storage.PersistedSegments.ping()
        :ok = Guardian.Storage.LoadedSegments.rescan()

        Guardian.Storage.FullSegments.segment_ids(table) == [] and
          Guardian.Storage.LoadedSegments.segment_ids(table) != []
      end,
      30_000,
      50
    )
  end

  @doc """
  Registers a one-call fake mutable segment for `table`, so the next append to it goes
  through the real Storage and GenServer path to `callback.(from, row)`, which replies
  (or fails) as the test needs. The fake unregisters itself before calling back, so
  later rows use real segments, and exits with the callback's exit reason. Call it from
  the test process: cleanup is `on_exit`. It writes MutableSegments' registry directly,
  which test code may do to inject faults (`lib/guardian/storage/AGENTS.md`).

  Every all-table schema read (SHOW TABLES, DESC, `schema`) in any concurrent test can
  reach the fake, and fails after 5 s without an answer, so the fake answers `:schema`
  until it exits, even during a slow callback. It answers no other call: nothing but
  this table's own readers makes them.
  """
  def intercept_append(table, callback) do
    segment_id = Guardian.SegmentID.generate()

    segment =
      spawn(fn ->
        # Trapping keeps it answering while the callback runs. A :kill still ends it,
        # and the link then ends the callback.
        Process.flag(:trap_exit, true)
        answer_as_fake_segment(segment_id, callback, nil)
      end)

    :sys.replace_state(Guardian.Storage.MutableSegments, fn state ->
      true = :ets.insert(Guardian.Storage.MutableSegments, {segment_id, segment, table})
      state
    end)

    ExUnit.Callbacks.on_exit(fn ->
      # Kill first: deletion stops the segment, and this fake one does not answer.
      Process.exit(segment, :kill)
      Guardian.Storage.MutableSegments.delete_segment(segment_id)
    end)
  end

  defp answer_as_fake_segment(segment_id, callback, callback_pid) do
    receive do
      {:"$gen_call", from, :schema} ->
        GenServer.reply(from, {:ok, %{}})
        answer_as_fake_segment(segment_id, callback, callback_pid)

      {:"$gen_call", from, {:append, row}} when callback_pid == nil ->
        # Unregister without stopping: deletion would stop this fake segment.
        :sys.replace_state(Guardian.Storage.MutableSegments, fn state ->
          true = :ets.delete(Guardian.Storage.MutableSegments, segment_id)
          state
        end)

        # The callback's reply comes back through this process: the caller's reply and
        # this process's exit must arrive in order, which the VM only promises for
        # signals from one sender. A scripted refusal that arrived after the exit would
        # look like a dead segment, and Storage would retry the row.
        relay = {self(), {:relay_reply, from}}
        callback_pid = spawn_link(fn -> callback.(relay, row) end)
        answer_as_fake_segment(segment_id, callback, callback_pid)

      {{:relay_reply, from}, reply} ->
        GenServer.reply(from, reply)
        answer_as_fake_segment(segment_id, callback, callback_pid)

      {:EXIT, ^callback_pid, reason} ->
        exit(reason)
    end
  end
end

defmodule Guardian.Test.Segments do
  @moduledoc """
  Builds segment fixtures and injects append failures. Tests must isolate their
  segments, filenames and tables; tests that suspend or replace shared Storage
  processes require `async: false`.
  """

  @doc """
  The ID and process of `table`'s full segment at `index` (by ID order), as queries
  find it: written and loaded. Until its file is loaded, a full segment also has an
  in-memory process, and LoadedSegments' periodic scan can load the file at any
  moment, after which queries read the loaded copy (lookups check it first). A test
  that suspends or kills the in-memory process would then find queries unaffected.
  Fails if the segment is never written, as for a mutable segment.
  """
  @spec loaded_segment(String.t(), non_neg_integer()) :: {String.t(), pid()}
  def loaded_segment(table, index) do
    id = table |> Guardian.Storage.segment_ids() |> Enum.sort() |> Enum.at(index)
    filename = Guardian.Storage.SegmentFile.filename(table, id)
    :ok = Guardian.Storage.PersistedSegments.ping()
    Guardian.Test.Polling.eventually(fn -> File.exists?(filename) end, 30_000)
    # Loads just this file, with no call timeout (a full rescan is a 5 s call).
    :ok = Guardian.Storage.LoadedSegments.ensure_loaded(table, id)
    {:ok, pid} = Guardian.Storage.LoadedSegments.get_segment(id)
    {:ok, ^pid} = Guardian.Storage.get_segment(id)
    {id, pid}
  end

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

  @doc """
  Hands off `table`'s mutable segments, as if each had filled; their rows stay readable.
  An append chooses among a table's mutable segments, so `intercept_append/2`'s fake
  gets the next append only if it is the only one: call this first for a table that
  can't be a fresh one, such as a built-in table. The table's writers must be idle.
  """
  def hand_off_mutable_segments(table) do
    for segment <- Guardian.Storage.MutableSegments.get_mutable_segments(table) do
      :ok = Guardian.Storage.MutableSegments.segment_is_full(table, segment)
    end

    :ok
  end
end

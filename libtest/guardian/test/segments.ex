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
  later rows use real segments. Call it from the test process: cleanup is `on_exit`.
  It writes MutableSegments' registry directly, which test code may do to inject
  faults (`lib/guardian/storage/CLAUDE.md`).
  """
  def intercept_append(table, callback) do
    segment_id = Guardian.SegmentID.generate()

    segment =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:append, row}} ->
            # Unregister without stopping: deletion would stop this fake segment.
            :sys.replace_state(Guardian.Storage.MutableSegments, fn state ->
              true = :ets.delete(Guardian.Storage.MutableSegments, segment_id)
              state
            end)

            callback.(from, row)
        end
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
end

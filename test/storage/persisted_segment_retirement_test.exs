defmodule Guardian.Storage.PersistedSegmentRetirementTest do
  # When a persisted segment's cache window ends and LoadedSegments serves its file,
  # PersistedSegments stops the in-memory process instead of leaving it running
  # unregistered, which would leak it.
  use ExUnit.Case, async: false
  import Guardian.TestHelpers

  alias Guardian.Storage.BlobStore
  alias Guardian.Storage.Column
  alias Guardian.Storage.LoadedSegments
  alias Guardian.Storage.MutableSegments
  alias Guardian.Storage.PersistedSegments
  alias Guardian.Storage.Schema
  alias Guardian.Storage.Segment

  setup do
    # Keep periodic persistence from moving a fixture before the intended boundary.
    :ok = :sys.suspend(PersistedSegments)
    on_exit(fn -> :ok = :sys.resume(PersistedSegments) end)
    :ok
  end

  test "the in-memory copy stops once its file is loaded, and queries keep every row" do
    {table, id, segment, registration} = persisted_fixture(3)
    ref = Process.monitor(segment)

    # Loaded ahead of the cache window, as the minute scan normally does.
    :ok = LoadedSegments.rescan()
    assert {:ok, loaded} = LoadedSegments.get_segment(id)
    assert loaded != segment
    assert {:ok, 3} = Schema.get_count(table)
    {:ok, schema_before} = Schema.get_schema(table)

    expire(registration)

    assert_receive {:DOWN, ^ref, :process, ^segment, :normal}
    assert :ets.lookup(PersistedSegments, id) == []
    assert {:ok, ^loaded} = Guardian.Storage.get_segment(id)
    assert Enum.to_list(Guardian.Storage.segment_ids(table)) == [id]
    # Guardian.Storage.Schema tracks only the loaded copy, so stopping this one changes nothing.
    assert {:ok, 3} = Schema.get_count(table)
    assert {:ok, ^schema_before} = Schema.get_schema(table)
    assert run_sql("select count() from #{table}") == [[3]]
    assert run_sql("select a from #{table} order by a") == [[1], [2], [3]]
    assert Process.whereis(PersistedSegments) |> Process.alive?()
  end

  test "the in-memory copy stops when the cache window loads the file itself" do
    # The minute scan can't register the file while LoadedSegments is suspended.
    {table, id, segment, registration} =
      with_loaded_suspended(fn ->
        fixture = persisted_fixture(2)
        assert {:error, :not_found} = LoadedSegments.get_segment(elem(fixture, 1))
        fixture
      end)

    ref = Process.monitor(segment)

    expire(registration)

    assert_receive {:DOWN, ^ref, :process, ^segment, :normal}
    assert {:ok, loaded} = Guardian.Storage.get_segment(id)
    assert loaded != segment
    assert run_sql("select count() from #{table}") == [[2]]
  end

  test "the in-memory copy stops when its file was deleted" do
    # Held so the minute scan can't load the file before it is deleted.
    {_table, id, segment, registration} =
      with_loaded_suspended(fn ->
        {table, id, _segment, _registration} = fixture = persisted_fixture(1)
        :ok = BlobStore.delete(Guardian.Storage.SegmentFile.filename(table, id))
        fixture
      end)

    ref = Process.monitor(segment)

    expire(registration)

    assert_receive {:DOWN, ^ref, :process, ^segment, :normal}
    assert {:error, :not_found} = Guardian.Storage.get_segment(id)
  end

  test "an unreadable file that cannot be repaired keeps the in-memory copy running" do
    # Held so the minute scan can't load the file before it is replaced. A nonempty
    # directory in the file's place: it does not load, and a rename cannot replace it.
    {{table, id, segment, registration}, filename} =
      with_loaded_suspended(fn ->
        {table, id, _segment, _registration} = fixture = persisted_fixture(1)
        filename = Guardian.Storage.SegmentFile.filename(table, id)
        :ok = BlobStore.delete(filename)
        File.mkdir_p!(Path.join(filename, "child"))
        {fixture, filename}
      end)

    on_exit(fn -> File.rm_rf!(filename) end)

    ExUnit.CaptureLog.capture_log(fn -> expire(registration) end)

    assert Process.alive?(segment)
    assert :ets.lookup(PersistedSegments, id) == [registration]
    assert run_sql("select count() from #{table}") == [[1]]
    File.rm_rf!(filename)
  end

  test "the later EXIT of the stopped copy is ignored, and a stale timer does nothing" do
    {table, id, segment, registration} = persisted_fixture(1)
    persister = Process.whereis(PersistedSegments)
    :ok = LoadedSegments.rescan()
    {:ok, loaded} = LoadedSegments.get_segment(id)
    expire(registration)
    refute Process.alive?(segment)

    # The stopped copy's EXIT waits in the persister's mailbox; let the persister
    # handle it.
    {:messages, messages} = Process.info(persister, :messages)
    assert Enum.member?(messages, {:EXIT, segment, :normal})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = :sys.resume(PersistedSegments)
        :sys.get_state(PersistedSegments)
        :ok = :sys.suspend(PersistedSegments)
      end)

    assert Process.whereis(PersistedSegments) == persister
    {:messages, messages} = Process.info(persister, :messages)
    refute Enum.member?(messages, {:EXIT, segment, :normal})
    refute log =~ "Persisted segment #{id}"
    assert :ets.lookup(PersistedSegments, id) == []

    # A stale timer for the same registration must not ask LoadedSegments again: with
    # LoadedSegments suspended, such a call would never return.
    with_loaded_suspended(fn -> expire(registration) end)

    assert {:ok, ^loaded} = LoadedSegments.get_segment(id)
    assert run_sql("select count() from #{table}") == [[1]]
  end

  test "a query counting the in-memory copy when it stops reads the file instead" do
    # The file is not loaded yet (LoadedSegments is held), so the query resolves the
    # in-memory copy. Hold the copy so the query blocks in its read, then end the
    # cache window.
    {{_table, _id, segment, registration}, task} =
      with_loaded_suspended(fn ->
        {table, _id, segment, _registration} = fixture = persisted_fixture(2)
        :ok = :sys.suspend(segment)
        task = Task.async(fn -> run_sql("select count() from #{table}") end)
        await_queued_call(segment, call: :count)
        {fixture, task}
      end)

    ref = Process.monitor(segment)
    expire(registration)
    assert_receive {:DOWN, ^ref, :process, ^segment, :normal}
    assert Task.await(task) == [[2]]
  end

  test "a query reading a column of the in-memory copy when it stops reads the file" do
    {{_table, id, segment, registration}, task} =
      with_loaded_suspended(fn ->
        {_table, id, segment, _registration} = fixture = persisted_fixture(3)
        snapshot = Guardian.Query.Evaluation.snapshot!(id)
        :ok = :sys.suspend(segment)

        task =
          Task.async(fn ->
            snapshot
            |> Guardian.Query.Evaluation.eval(%Guardian.AST.Node.Identifier{name: "a"})
            |> Column.to_list()
          end)

        await_queued_call(segment, call: {:get_column, "a"})
        {fixture, task}
      end)

    ref = Process.monitor(segment)
    expire(registration)
    assert_receive {:DOWN, ^ref, :process, ^segment, :normal}
    assert Task.await(task) == [1, 2, 3]
    assert {:ok, loaded} = Guardian.Storage.get_segment(id)
    assert loaded != segment
  end

  test "a query reading the in-memory copy when it stops fails if no copy is left" do
    # The file is deleted, so retiring the in-memory copy leaves nothing to retry on.
    {{_table, id, segment, registration}, task} =
      with_loaded_suspended(fn ->
        {table, id, segment, _registration} = fixture = persisted_fixture(1)
        :ok = BlobStore.delete(Guardian.Storage.SegmentFile.filename(table, id))
        :ok = :sys.suspend(segment)
        task = Task.async(fn -> catch_error(run_sql("select count() from #{table}")) end)
        await_queued_call(segment, call: :count)
        {fixture, task}
      end)

    ref = Process.monitor(segment)
    expire(registration)
    assert_receive {:DOWN, ^ref, :process, ^segment, :normal}

    assert %Guardian.Query.Error{message: message} = Task.await(task)

    assert message ==
             "segment #{id} became unavailable during the query " <>
               "(it was deleted, expired, or moved to its file)"
  end

  test "a PID looked up before the stop and read after it is retried on the file" do
    {_table, id, segment, registration} =
      with_loaded_suspended(fn ->
        {_table, id, segment, _registration} = fixture = persisted_fixture(1)
        assert {:ok, ^segment} = Guardian.Storage.get_segment(id)
        fixture
      end)

    expire(registration)

    assert {:error, {:segment_unavailable, :noproc}} = Segment.count(segment)
    assert {:ok, 1} = Guardian.Storage.read_segment(id, segment, &Segment.count/1)
    assert {:ok, loaded} = Guardian.Storage.get_segment(id)
    assert loaded != segment
  end

  test "a read is retried once, only after a normal stop, and only on another copy" do
    {_table, id, segment, registration} = persisted_fixture(1)
    :ok = LoadedSegments.rescan()
    expire(registration)
    {:ok, loaded} = Guardian.Storage.get_segment(id)

    # Each read reports the PID it was given; `results` maps PIDs to replies.
    reader = fn results ->
      fn pid ->
        send(self(), {:read, pid})
        Map.fetch!(results, pid)
      end
    end

    unavailable = &{:error, {:segment_unavailable, &1}}
    crash = {%RuntimeError{message: "row data"}, []}

    # A second failure is returned, with its own reason, even one that could retry.
    read = reader.(%{segment => unavailable.(:normal), loaded => unavailable.(:noproc)})
    assert unavailable.(:noproc) == Guardian.Storage.read_segment(id, segment, read)
    assert_received {:read, ^segment}
    assert_received {:read, ^loaded}
    refute_received {:read, _}

    # A crash is not retried.
    read = reader.(%{segment => unavailable.(crash)})
    assert unavailable.(crash) == Guardian.Storage.read_segment(id, segment, read)
    assert_received {:read, ^segment}
    refute_received {:read, _}

    # Nor a stop when the ID still resolves to the same process.
    read = reader.(%{loaded => unavailable.(:shutdown)})
    assert unavailable.(:shutdown) == Guardian.Storage.read_segment(id, loaded, read)
    assert_received {:read, ^loaded}
    refute_received {:read, _}

    # Nor a stop when the ID resolves to nothing.
    :ok = :sys.resume(PersistedSegments)
    :ok = Guardian.Storage.delete_segment(id)
    read = reader.(%{loaded => unavailable.(:noproc)})
    assert unavailable.(:noproc) == Guardian.Storage.read_segment(id, loaded, read)
    assert_received {:read, ^loaded}
    refute_received {:read, _}
  end

  # The invariant the read retry in Guardian.Storage.read_segment/3 relies on: a query's snapshot row count bounds a read from the saved copy exactly
  # as it bounds a read from the in-memory copy, so a query can read some columns from
  # one copy and the rest from the other and still see the same rows.
  test "a snapshot taken from the in-memory copy reads the same rows from the saved copy" do
    table = table()
    # "b" is missing from some early rows; "c" first appears after the snapshot.
    early =
      for j <- 1..5, do: if(rem(j, 2) == 0, do: %{"a" => j, "b" => "b#{j}"}, else: %{"a" => j})

    late = for j <- 6..9, do: %{"a" => j, "b" => "b#{j}", "c" => j}
    for row <- early, do: :ok = Guardian.Storage.append(table, row)

    [id] = MutableSegments.segment_ids(table)
    [{^id, segment, ^table} = registration] = :ets.lookup(MutableSegments, id)
    snapshot = Guardian.Query.Evaluation.snapshot!(id)
    assert snapshot.count == 5

    read = fn key ->
      snapshot
      |> Guardian.Query.Evaluation.eval(%Guardian.AST.Node.Identifier{name: key})
      |> Column.to_list()
    end

    a_in_memory = read.("a")
    assert a_in_memory == [1, 2, 3, 4, 5]

    # The segment gains rows after the snapshot, then is saved, loaded and retired.
    for row <- late, do: :ok = Guardian.Storage.append(table, row)
    ref = Process.monitor(segment)
    :ok = Segment.freeze(segment)
    :ok = MutableSegments.segment_is_full(table, segment)

    :sys.replace_state(PersistedSegments, fn state ->
      {:noreply, next} = PersistedSegments.handle_cast(:ping, state)
      next
    end)

    :ok = LoadedSegments.rescan()
    expire(registration)
    assert_receive {:DOWN, ^ref, :process, ^segment, :normal}
    assert {:ok, loaded} = Guardian.Storage.get_segment(id)
    assert loaded != segment
    assert {:ok, 9} = Guardian.Storage.segment_row_count(id)

    # The same snapshot, now read from the file: the first 5 rows, column by column.
    assert read.("a") == a_in_memory
    assert read.("b") == [nil, "b2", nil, "b4", nil]
    assert read.("c") == [nil, nil, nil, nil, nil]
    assert read.("d") == [nil, nil, nil, nil, nil]

    # The file holds every row, so a fresh snapshot sees them all.
    fresh = Guardian.Query.Evaluation.snapshot!(id)
    assert fresh.count == 9

    assert Guardian.Query.Evaluation.eval(fresh, %Guardian.AST.Node.Identifier{name: "c"})
           |> Column.to_list() ==
             [nil, nil, nil, nil, nil, 6, 7, 8, 9]
  end

  test "an invalid cache window stops the persister from starting" do
    previous = Application.fetch_env(:guardian, :persisted_segment_cache_ms)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:guardian, :persisted_segment_cache_ms, value)
        :error -> Application.delete_env(:guardian, :persisted_segment_cache_ms)
      end
    end)

    for invalid <- [0, -1, 1.5, "600000", nil] do
      Application.put_env(:guardian, :persisted_segment_cache_ms, invalid)

      assert_raise ArgumentError, "persisted_segment_cache_ms must be a positive integer", fn ->
        PersistedSegments.init([])
      end
    end
  end

  test "the configured cache window ends with the in-memory copy stopped" do
    previous = Application.fetch_env(:guardian, :persisted_segment_cache_ms)
    Application.put_env(:guardian, :persisted_segment_cache_ms, 50)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:guardian, :persisted_segment_cache_ms, value)
        :error -> Application.delete_env(:guardian, :persisted_segment_cache_ms)
      end
    end)

    :ok = :sys.resume(PersistedSegments)
    table = table()
    :ok = Guardian.Storage.append(table, %{"a" => 1})
    [{id, segment, ^table}] = :ets.lookup(MutableSegments, hd(MutableSegments.segment_ids(table)))
    ref = Process.monitor(segment)
    :ok = Segment.freeze(segment)
    :ok = MutableSegments.segment_is_full(table, segment)

    assert_receive {:DOWN, ^ref, :process, ^segment, :normal}, 5_000
    assert {:ok, loaded} = Guardian.Storage.get_segment(id)
    assert loaded != segment
    assert run_sql("select count() from #{table}") == [[1]]
  end

  defp persisted_fixture(rows) do
    table = table()
    for a <- 1..rows, do: :ok = Guardian.Storage.append(table, %{"a" => a})
    [id] = MutableSegments.segment_ids(table)
    [{^id, segment, ^table} = registration] = :ets.lookup(MutableSegments, id)
    :ok = Segment.freeze(segment)
    :ok = MutableSegments.segment_is_full(table, segment)

    # Persist it, inside the (suspended) persister.
    :sys.replace_state(PersistedSegments, fn state ->
      {:noreply, next} = PersistedSegments.handle_cast(:ping, state)
      next
    end)

    assert :ets.lookup(PersistedSegments, id) == [registration]
    {table, id, segment, registration}
  end

  # Fires the end of the cache window inside the persister, as its timer does.
  defp expire(registration) do
    :sys.replace_state(PersistedSegments, fn state ->
      {:noreply, next} = PersistedSegments.handle_info({:delete, registration}, state)
      next
    end)

    :ok
  end

  defp table do
    table = "retire_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

    on_exit(fn ->
      # Deletion calls the persister, so it must be running.
      :ok = :sys.resume(PersistedSegments)
      Guardian.Storage.delete_table(table)
    end)

    table
  end

  # Runs `fun` while LoadedSegments handles nothing, so its minute scan can't register
  # a fixture's file in between.
  defp with_loaded_suspended(fun) do
    :ok = :sys.suspend(LoadedSegments)

    try do
      fun.()
    after
      :ok = :sys.resume(LoadedSegments)
    end
  end
end

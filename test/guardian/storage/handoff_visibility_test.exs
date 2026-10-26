defmodule Guardian.Storage.HandoffVisibilityTest do
  use ExUnit.Case, async: false
  import Guardian.Test.Query
  import Guardian.Test.Processes

  alias Guardian.Storage.BlobStore
  alias Guardian.Storage.FullSegments
  alias Guardian.Storage.LoadedSegments
  alias Guardian.Storage.MutableSegments
  alias Guardian.Storage.PersistedSegments
  alias Guardian.Storage.Segment

  @registries [MutableSegments, FullSegments, PersistedSegments, LoadedSegments]

  setup do
    # Keep periodic persistence from moving a fixture before the intended boundary.
    :ok = :sys.suspend(PersistedSegments)
    on_exit(fn -> :ok = :sys.resume(PersistedSegments) end)
    :ok
  end

  test "complete and unloaded snapshots follow handoffs at every observed read boundary" do
    for {api, expected, transitions} <- [
          {:segment_ids, @registries, [:mutable, :full, :persisted]},
          {:unloaded_segment_ids, Enum.take(@registries, 3), [:mutable, :full]},
        ] do
      order =
        observed_reads(:segment_ids, fn ->
          apply(Guardian.Storage, api, ["missing_handoff_table"])
        end)

      assert order == expected

      for source <- transitions, boundary <- 0..length(order) do
        {table, id, _segment, registration} = fixture(source)

        ids =
          order
          |> Enum.with_index()
          |> Enum.flat_map(fn {registry, index} ->
            if index == boundary, do: transfer(source, registration)
            registry.segment_ids(table)
          end)
          |> Enum.uniq()

        assert ids == [id], "#{api}: #{source} transfer before registry #{boundary}"
        if boundary == length(order), do: transfer(source, registration)
        assert Enum.to_list(Guardian.Storage.segment_ids(table)) == [id]
        cleanup(table)
      end
    end
  end

  test "lookup retries Loaded after the forward miss path at every observed boundary" do
    order =
      observed_reads(:get_segment, fn ->
        Guardian.Storage.get_segment(Guardian.SegmentID.generate())
      end)

    assert order == [
             LoadedSegments,
             MutableSegments,
             FullSegments,
             PersistedSegments,
             LoadedSegments,
           ]

    for source <- [:mutable, :full, :persisted], boundary <- 0..(length(order) - 1) do
      {table, _id, _segment, registration} = fixture(source)
      {id, _, _} = registration

      result =
        order
        |> Enum.with_index()
        |> Enum.reduce_while({:error, :not_found}, fn {registry, index}, _ ->
          if index == boundary, do: transfer(source, registration)

          case registry.get_segment(id) do
            {:ok, _} = found -> {:halt, found}
            missing -> {:cont, missing}
          end
        end)

      assert {:ok, segment} = result
      assert {:ok, 1} = Segment.count(segment)
      cleanup(table)
    end
  end

  test "queries retain the rows when cache expires before a disk scan" do
    {table, id, _segment, registration} = fixture(:persisted)
    assert {:error, :not_found} = LoadedSegments.get_segment(id)

    transfer(:persisted, registration)
    assert {:error, :not_found} = PersistedSegments.get_segment(id)
    assert {:ok, loaded} = LoadedSegments.get_segment(id)
    assert Enum.to_list(Guardian.Storage.segment_ids(table)) == [id]
    assert_query_rows(table)

    # Repeated ensures and the same stale expiry do not duplicate loaded metadata.
    assert :ok = LoadedSegments.ensure_loaded(table, id)
    transfer(:persisted, registration)
    assert {:ok, ^loaded} = LoadedSegments.get_segment(id)
    assert {:ok, 1} = Guardian.Storage.Schema.get_count(table)
    cleanup(table)
  end

  test "a delayed Loaded manager cannot evict the cache before registration completes" do
    {table, id, _segment, registration} = fixture(:persisted)
    :ok = :sys.suspend(LoadedSegments)
    on_exit(fn -> :ok = :sys.resume(LoadedSegments) end)

    # Resume only the persistence manager so it can start the real expiry callback.
    send(PersistedSegments, {:delete, registration})
    :ok = :sys.resume(PersistedSegments)

    await_queued_call(Process.whereis(LoadedSegments), call: {:ensure_loaded, table, id})

    assert :ets.lookup(PersistedSegments, id) == [registration]
    assert {:error, :not_found} = LoadedSegments.get_segment(id)
    assert Enum.to_list(Guardian.Storage.segment_ids(table)) == [id]
    assert {:ok, _} = Guardian.Storage.get_segment(id)

    :ok = :sys.resume(LoadedSegments)
    :sys.get_state(PersistedSegments)
    assert {:error, :not_found} = PersistedSegments.get_segment(id)
    assert {:ok, _} = LoadedSegments.get_segment(id)
    assert_query_rows(table)
    cleanup(table)
  end

  test "stale expiry does not reload a removed cache entry or recreate a deleted file" do
    {table, id, _segment, registration} = fixture(:persisted)

    :sys.replace_state(PersistedSegments, fn state ->
      true = :ets.delete(PersistedSegments, id)
      {_id, segment, _table} = registration
      Process.unlink(segment)
      state
    end)

    transfer(:persisted, registration)
    assert {:error, :not_found} = LoadedSegments.get_segment(id)

    filename = Guardian.Storage.SegmentFile.filename(table, id)
    assert BlobStore.exists(filename)
    :ok = BlobStore.delete(filename)
    assert {:error, :not_found} = LoadedSegments.ensure_loaded(table, id)
    cleanup(table)
  end

  test "expiry of a current cache entry whose file was removed does not reload it" do
    {table, id, _segment, registration} = fixture(:persisted)
    :ok = BlobStore.delete(Guardian.Storage.SegmentFile.filename(table, id))
    transfer(:persisted, registration)
    assert {:error, :not_found} = Guardian.Storage.get_segment(id)
    assert Enum.to_list(Guardian.Storage.segment_ids(table)) == []
    cleanup(table)
  end

  test "cache expiry rewrites an unreadable persisted file from memory" do
    {table, id, segment, registration} = fixture(:persisted)
    filename = Guardian.Storage.SegmentFile.filename(table, id)
    File.write!(filename, "")
    ref = Process.monitor(segment)

    log = ExUnit.CaptureLog.capture_log(fn -> transfer(:persisted, registration) end)

    assert log =~ "Rewriting unreadable segment file #{filename}"
    # Once the rewritten file is loaded, the in-memory copy is stopped.
    assert_receive {:DOWN, ^ref, :process, ^segment, :normal}
    assert {:error, :not_found} = PersistedSegments.get_segment(id)
    assert {:ok, _loaded} = LoadedSegments.get_segment(id)
    refute id in LoadedSegments.skipped_segment_ids()
    assert {:ok, 1} = Guardian.Storage.Schema.get_count(table)
    assert_query_rows(table)
    cleanup(table)
  end

  test "cache expiry keeps serving a segment whose file cannot be repaired" do
    {table, id, _segment, registration} = fixture(:persisted)
    filename = Guardian.Storage.SegmentFile.filename(table, id)
    # A nonempty directory in the file's place: it does not load, and a rename
    # cannot replace it.
    :ok = BlobStore.delete(filename)
    File.mkdir_p!(Path.join(filename, "child"))
    on_exit(fn -> File.rm_rf!(filename) end)

    log = ExUnit.CaptureLog.capture_log(fn -> transfer(:persisted, registration) end)

    assert log =~ "still unreadable"
    assert :ets.lookup(PersistedSegments, id) == [registration]
    assert {:error, :not_found} = LoadedSegments.get_segment(id)
    assert_query_rows(table)

    File.rm_rf!(filename)
    cleanup(table)
  end

  test "concurrent production snapshots and lookups retain an ID through all handoffs" do
    {table, id, segment, registration} = fixture(:mutable)
    parent = self()

    reader =
      Task.async(fn ->
        send(parent, :reader_started)

        for _ <- 1..1000 do
          assert Enum.to_list(Guardian.Storage.segment_ids(table)) == [id]
          assert {:ok, found} = Guardian.Storage.get_segment(id)

          # The in-memory copy is stopped once its file is loaded, so a lookup that
          # returned it just before then may find it gone. Looking the ID up again
          # finds the loaded copy.
          case Segment.count(found) do
            {:ok, 1} ->
              :ok

            # `:normal` if the call was queued behind the stop, `:noproc` if it came
            # after the copy was gone.
            {:error, {:segment_unavailable, reason}} when reason in [:normal, :noproc] ->
              assert {:ok, loaded} = LoadedSegments.get_segment(id)
              assert loaded != found
              assert {:ok, 1} = Segment.count(loaded)
          end
        end
      end)

    assert_receive :reader_started
    :ok = Segment.freeze(segment)
    :ok = MutableSegments.segment_is_full(table, segment)
    persist_pending()
    transfer(:persisted, registration)
    Task.await(reader)
    assert_query_rows(table)
    cleanup(table)
  end

  defp fixture(source) do
    table = "handoff_#{System.unique_integer([:positive])}"
    :ok = Guardian.Storage.append(table, %{"a" => 1})
    [id] = MutableSegments.segment_ids(table)
    [{^id, segment, ^table} = registration] = :ets.lookup(MutableSegments, id)

    on_exit(fn ->
      :ok = :sys.resume(PersistedSegments)
      cleanup(table)
      if Process.alive?(segment), do: GenServer.stop(segment, :normal)
    end)

    if source in [:full, :persisted], do: transfer(:mutable, registration)
    if source == :persisted, do: persist_pending()
    {table, id, segment, registration}
  end

  defp transfer(:mutable, {_id, segment, table}) do
    :ok = Segment.freeze(segment)
    :ok = MutableSegments.segment_is_full(table, segment)
  end

  defp transfer(:full, _registration) do
    persist_pending()
  end

  defp transfer(:persisted, registration) do
    :sys.replace_state(PersistedSegments, fn state ->
      {:noreply, next} = PersistedSegments.handle_info({:delete, registration}, state)
      next
    end)

    :ok
  end

  defp persist_pending do
    :sys.replace_state(PersistedSegments, fn state ->
      {:noreply, next} = PersistedSegments.handle_cast(:ping, state)
      next
    end)

    :ok
  end

  defp cleanup(table) do
    # System requests work while Persisted is suspended; regular delete calls do not.
    for registry <- @registries do
      :sys.replace_state(registry, fn state ->
        Enum.reduce(registry.segment_ids(table), state, fn id, current ->
          {:ok, segment} = registry.get_segment(id)
          Process.unlink(segment)
          {:reply, :ok, next} = registry.handle_call({:delete_segment, id}, nil, current)
          next
        end)
      end)
    end

    for filename <- Path.wildcard(Path.join(Guardian.Storage.segment_dir(), "#{table}.*.seg")) do
      :ok = BlobStore.delete(filename)
    end
  end

  defp assert_query_rows(table) do
    assert run_sql("select a from #{table}") == [[1]]
    assert run_sql("select count() from #{table}") == [[1]]
  end

  # Trace the production traversal, then replay its actual order at legal handoff
  # boundaries. Tracing observes calls; replay supplies deterministic interleavings.
  defp observed_reads(function, fun) do
    parent = self()

    reader =
      spawn(fn ->
        receive do
          :run ->
            fun.()
            send(parent, :reads_finished)

            receive do
              :stop -> :ok
            end
        end
      end)

    try do
      for registry <- @registries do
        :erlang.trace_pattern({registry, function, 1}, true, [:local])
      end

      :erlang.trace(reader, true, [:call, {:tracer, self()}])
      send(reader, :run)
      assert_receive :reads_finished
      ref = :erlang.trace_delivered(reader)
      collect_reads(reader, ref, [])
    after
      :erlang.trace(reader, false, [:all])

      for registry <- @registries do
        :erlang.trace_pattern({registry, function, 1}, false, [:local])
      end

      send(reader, :stop)
    end
  end

  defp collect_reads(reader, ref, modules) do
    receive do
      {:trace, ^reader, :call, {module, _, _}} -> collect_reads(reader, ref, [module | modules])
      {:trace_delivered, ^reader, ^ref} -> Enum.reverse(modules)
    after
      1000 -> flunk("registry call traces were not delivered")
    end
  end
end

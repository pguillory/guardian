defmodule Guardian.Storage.SegmentOwnerExitsTest do
  # Each lifecycle manager owns its segments' exits: a segment that dies is
  # unregistered without taking its manager down, and a manager that stops or deletes
  # a segment stops its process.
  use ExUnit.Case, async: false
  import Guardian.TestHelpers
  import ExUnit.CaptureLog

  alias Guardian.Storage.FullSegments
  alias Guardian.Storage.LoadedSegments
  alias Guardian.Storage.MutableSegments
  alias Guardian.Storage.PersistedSegments
  alias Guardian.Storage.Schema
  alias Guardian.Storage.Segment
  alias Guardian.Storage.Segment.Registration
  require Registration

  @managers [Schema, LoadedSegments, FullSegments, PersistedSegments, MutableSegments]
  @registries [MutableSegments, FullSegments, PersistedSegments, LoadedSegments]

  defp table do
    "owner_exits_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  end

  # A table whose segment filenames exceed the filesystem's 255-byte name limit, so its
  # full segments stay in FullSegments (the persister logs them and retries).
  defp unstorable_table do
    table() <> String.duplicate("f", 230)
  end

  # Every stored value of `v` in the table, sorted, so a lost or duplicated row shows.
  defp values(table) do
    run_sql("select v from #{table}") |> Enum.map(&hd/1) |> Enum.sort()
  end

  defp managers do
    Map.new([Guardian.Storage | @managers], &{&1, Process.whereis(&1)})
  end

  # Lets each manager handle every message already in its mailbox.
  defp sync do
    Enum.each(@managers, &:sys.get_state/1)
  end

  # Kills a process and returns once it is gone.
  defp kill(pid, reason) do
    ref = Process.monitor(pid)
    Process.exit(pid, reason)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  defp registered?(pid) do
    Enum.any?(@registries, fn registry ->
      :ets.tab2list(registry) |> Enum.any?(&match?({_, ^pid, _}, &1))
    end)
  end

  # Storage allows 3 restarts in 5 s, and each manager stop here is one. Keeps at most
  # two others in any 6.5 s window (the supervisor counts in whole seconds).
  defp space_restarts do
    now = System.monotonic_time(:millisecond)
    recent = :persistent_term.get(__MODULE__, []) |> Enum.filter(&(&1 > now - 6_500))

    now =
      case Enum.sort(recent) do
        [oldest, _ | _] ->
          Process.sleep(oldest + 6_500 - now)
          System.monotonic_time(:millisecond)

        _ ->
          now
      end

    :persistent_term.put(__MODULE__, [now | recent])
  end

  defp await_storage_ready do
    # A manager stop persists every writable segment on the way down and the restart
    # loads the files.
    eventually(
      fn -> Guardian.Storage.ready?() and Enum.all?(@managers, &Process.whereis/1) end,
      15_000
    )

    sync()
  end

  defp segment(rows) do
    {:ok, segment} = Segment.start_link()
    for v <- rows, do: :ok = Segment.append(segment, %{"v" => v})
    Process.unlink(segment)
    segment
  end

  defp full_fixture(table, rows) do
    segment = segment(rows)
    id = Guardian.SegmentID.generate()
    :ok = FullSegments.insert({id, segment, table})
    {id, segment}
  end

  defp loaded_fixture(table, rows) do
    segment = segment(rows)
    id = Guardian.SegmentID.generate()
    :ok = Segment.pack(segment)
    filename = Guardian.Storage.SegmentFile.filename(table, id)
    :ok = Segment.store(segment, filename)
    :ok = Segment.retire(segment)
    on_exit(fn -> File.rm(filename) end)
    :ok = LoadedSegments.rescan()
    {:ok, loaded} = LoadedSegments.get_segment(id)
    {id, loaded, filename}
  end

  defp persisted_fixture(table, rows) do
    {id, segment} = full_fixture(table, rows)
    on_exit(fn -> File.rm(Guardian.Storage.SegmentFile.filename(table, id)) end)
    :ok = PersistedSegments.ping()
    eventually(fn -> PersistedSegments.get_segment(id) == {:ok, segment} end)
    {id, segment}
  end

  # Unpersisted rows in another table, which a cascade through the managers would lose.
  defp bystander do
    table = table()
    for v <- 1..200, do: :ok = Guardian.Storage.append(table, %{"v" => v})
    on_exit(fn -> Guardian.Storage.delete_table(table) end)
    table
  end

  # Calls `request` in a task while `manager` is suspended, runs `between` once the
  # request is queued, then lets the manager handle the queue in order.
  defp queued_while_suspended(manager, request, between) do
    pid = Process.whereis(manager)
    :ok = :sys.suspend(pid)

    try do
      task = Task.async(request)

      eventually(fn ->
        {:messages, messages} = Process.info(pid, :messages)
        Enum.any?(messages, &match?({:"$gen_call", {from, _}, _} when from == task.pid, &1))
      end)

      between.()
      :ok = :sys.resume(pid)
      Task.await(task, 10_000)
    after
      :sys.resume(pid)
    end
  end

  # Reads the table's values repeatedly while `fun` runs, and returns every read
  # (at least one).
  defp reading_during(table, fun) do
    parent = self()
    reader = spawn_link(fn -> send(parent, {:reads, read_until_stopped(table, [])}) end)
    fun.()
    send(reader, :stop)
    assert_receive {:reads, reads}, 30_000
    reads
  end

  defp read_until_stopped(table, reads) do
    reads = [read(table) | reads]

    receive do
      :stop -> reads
    after
      0 -> read_until_stopped(table, reads)
    end
  end

  defp read(table) do
    values(table)
  catch
    kind, _ -> {:error, kind}
  end

  describe "a segment that dies does not take its manager down" do
    test "a mutable segment: only its own rows are lost, and its rows are not logged" do
      bystander = bystander()
      table = table()
      :ok = Guardian.Storage.append(table, %{"v" => 1})
      [{id, segment, ^table}] = :ets.match_object(MutableSegments, {:_, :_, table})
      before = managers()
      marker = "marker_#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          kill(segment, {%RuntimeError{message: marker}, []})
          eventually(fn -> MutableSegments.get_segment(id) == {:error, :not_found} end)
          sync()
        end)

      assert log =~ "Dropping dead mutable segment #{id}"
      assert log =~ "(RuntimeError)"
      refute log =~ marker
      assert managers() == before
      assert values(table) == []
      assert values(bystander) == Enum.to_list(1..200)
      Guardian.Storage.delete_table(table)
    end

    test "a full segment: only its own rows are lost" do
      bystander = bystander()
      table = unstorable_table()
      {id, segment} = full_fixture(table, 1..10)
      assert values(table) == Enum.to_list(1..10)
      before = managers()

      reads =
        reading_during(bystander, fn ->
          kill(segment, :boom)
          eventually(fn -> FullSegments.get_segment(id) == {:error, :not_found} end)
        end)

      sync()
      assert managers() == before
      assert values(table) == []
      assert values(bystander) == Enum.to_list(1..200)
      assert Enum.all?(reads, &(&1 == Enum.to_list(1..200)))
    end

    test "a persisted segment: its rows are served from its file" do
      bystander = bystander()
      table = table()
      {id, segment} = persisted_fixture(table, 1..10)
      before = managers()

      kill(segment, :boom)
      eventually(fn -> PersistedSegments.get_segment(id) == {:error, :not_found} end)

      sync()
      assert managers() == before
      :ok = LoadedSegments.rescan()
      assert values(table) == Enum.to_list(1..10)
      assert values(bystander) == Enum.to_list(1..200)
    end

    for reason <- [:boom, :normal] do
      test "a loaded segment (#{reason}) is reloaded by the next scan" do
        bystander = bystander()
        table = table()
        {id, loaded, _filename} = loaded_fixture(table, 1..10)
        assert values(table) == Enum.to_list(1..10)
        before = managers()

        reads =
          reading_during(table, fn ->
            if unquote(reason) == :normal,
              do: :ok = GenServer.stop(loaded, :normal),
              else: kill(loaded, :boom)

            eventually(fn -> LoadedSegments.get_segment(id) == {:error, :not_found} end)
            :ok = LoadedSegments.rescan()
          end)

        sync()
        assert managers() == before
        assert {:ok, reloaded} = LoadedSegments.get_segment(id)
        assert reloaded != loaded
        assert values(table) == Enum.to_list(1..10)
        assert Guardian.Storage.table_row_count(table) == 10
        assert values(bystander) == Enum.to_list(1..200)
        # Never a duplicate or a partial set: the segment is either seen whole or not.
        assert Enum.all?(reads, &(&1 in [Enum.to_list(1..10), []] or match?({:error, _}, &1)))
      end
    end

    test "a late EXIT from an old process leaves the ID's new registration alone" do
      table = table()
      {id, old, filename} = loaded_fixture(table, 1..10)

      # The EXIT from `old` is queued behind a reload that registers a new process
      # for the same ID, as if the scan had replaced it.
      :ok = :sys.suspend(LoadedSegments)

      try do
        kill(old, :boom)

        :sys.replace_state(LoadedSegments, fn state ->
          {:ok, new} = Segment.load(filename)
          true = :ets.insert(LoadedSegments, {id, new, table})
          {:ok, schema} = Segment.schema(new)
          :ok = Schema.add_segment({id, new, table}, schema)
          state
        end)
      after
        :ok = :sys.resume(LoadedSegments)
      end

      sync()
      assert {:ok, new} = LoadedSegments.get_segment(id)
      assert new != old and Process.alive?(new)
      assert values(table) == Enum.to_list(1..10)
      assert Guardian.Storage.table_row_count(table) == 10
    end

    test "a handoff of a segment that already died leaves no registration" do
      dead = spawn(fn -> :ok end)
      eventually(fn -> not Process.alive?(dead) end)
      before = managers()
      id = Guardian.SegmentID.generate()

      assert :ok = FullSegments.insert({id, dead, table()})
      eventually(fn -> FullSegments.get_segment(id) == {:error, :not_found} end)
      sync()
      assert managers() == before
    end
  end

  test "normal exits are told apart from crashes" do
    assert Segment.normal_exit?(:normal)
    assert Segment.normal_exit?(:shutdown)
    assert Segment.normal_exit?({:shutdown, :x})
    refute Segment.normal_exit?(:boom)
  end

  describe "a segment that dies between selection and stop" do
    test "does not crash LoadedSegments on deletion or rescan" do
      before = managers()
      {id, loaded, filename} = loaded_fixture(table(), 1..3)

      assert :ok =
               queued_while_suspended(
                 LoadedSegments,
                 fn -> LoadedSegments.delete_segment(id) end,
                 fn -> kill(loaded, :kill) end
               )

      refute File.exists?(filename)

      {id, loaded, filename} = loaded_fixture(table(), 1..3)
      File.rm!(filename)

      assert :ok =
               queued_while_suspended(
                 LoadedSegments,
                 fn -> LoadedSegments.rescan() end,
                 fn -> kill(loaded, :kill) end
               )

      assert LoadedSegments.get_segment(id) == {:error, :not_found}
      sync()
      assert managers() == before
    end

    test "does not crash the manager deleting a mutable, full or persisted segment" do
      before = managers()
      table = table()
      :ok = Guardian.Storage.append(table, %{"v" => 1})
      [{mutable_id, mutable, ^table}] = :ets.match_object(MutableSegments, {:_, :_, table})
      {persisted_id, persisted} = persisted_fixture(table, 1..2)
      full_table = unstorable_table()
      {full_id, full} = full_fixture(full_table, 1..2)

      for {manager, id, segment} <- [
            {MutableSegments, mutable_id, mutable},
            {FullSegments, full_id, full},
            {PersistedSegments, persisted_id, persisted},
          ] do
        assert :ok =
                 queued_while_suspended(
                   manager,
                   fn -> manager.delete_segment(id) end,
                   fn -> kill(segment, :kill) end
                 )

        assert manager.get_segment(id) == {:error, :not_found}
      end

      sync()
      assert managers() == before
      :ok = Guardian.Storage.delete_table(table)
    end
  end

  test "deleting a table stops its mutable, full and persisted segments" do
    table = table()
    :ok = MutableSegments.ensure_at_least_n_mutable_segments(table, 3)
    for v <- 1..30, do: :ok = Guardian.Storage.append(table, %{"v" => v})
    mutable = MutableSegments.get_mutable_segments(table)
    assert length(mutable) == 3
    {_id, persisted} = persisted_fixture(table, 31..40)
    # Loaded must know the file, or deletion leaves it to be loaded again by a scan
    # (deletion racing persistence is a separate, known gap).
    :ok = LoadedSegments.rescan()
    assert values(table) == Enum.to_list(1..40)

    full_table = unstorable_table()
    {_id, full} = full_fixture(full_table, 1..10)

    segments = [persisted, full | mutable]
    refs = Map.new(segments, &{Process.monitor(&1), &1})

    :ok = Guardian.Storage.delete_table(table)
    :ok = Guardian.Storage.delete_table(full_table)

    for _ <- segments do
      assert_receive {:DOWN, ref, :process, _, _} when is_map_key(refs, ref)
    end

    assert Enum.to_list(Guardian.Storage.segment_ids(table)) == []
    assert Enum.to_list(Guardian.Storage.segment_ids(full_table)) == []
    assert values(table) == []
  end

  describe "Guardian.Storage.schema/1 and a mutable segment" do
    test "skips one that died after being listed" do
      table = table()
      :ok = Guardian.Storage.append(table, %{"v" => 1})
      [{_id, segment, ^table}] = :ets.match_object(MutableSegments, {:_, :_, table})
      manager = Process.whereis(MutableSegments)

      # Suspended, the manager cannot unregister the dead segment, so it is still
      # listed when schema/1 reads it.
      :ok = :sys.suspend(manager)

      try do
        kill(segment, :kill)
        assert Guardian.Storage.schema(table) == %{}
      after
        :ok = :sys.resume(manager)
      end

      sync()
    end

    test "fails the lookup, by kind only, on one that does not answer" do
      table = table()
      :ok = Guardian.Storage.append(table, %{"v" => 1})
      [{_id, segment, ^table}] = :ets.match_object(MutableSegments, {:_, :_, table})
      :ok = :sys.suspend(segment)

      try do
        assert catch_exit(Guardian.Storage.schema(table)) == {:segment_unavailable, ":timeout"}
      after
        :ok = :sys.resume(segment)
      end

      assert Map.keys(Guardian.Storage.schema(table)) == ["v"]
      :ok = Guardian.Storage.delete_table(table)
    end
  end

  describe "a manager that exits" do
    # Stopping a manager makes MutableSegments hand off, and PersistedSegments write,
    # every table's writable segments, including other tests' fixed-name tables. Remove
    # the files written during the test (including those the setup's flush writes for
    # earlier tests, which the stop would otherwise have written) so later tests in this
    # run, which may reuse those names, don't load them.
    setup do
      before = segment_files()

      on_exit(fn ->
        await_storage_ready()
        segment_files() |> MapSet.difference(before) |> Enum.each(&File.rm/1)
        :ok = LoadedSegments.rescan()
      end)

      persist_writable_segments()
    end

    defp segment_files do
      Path.wildcard(Path.join(Guardian.Storage.segment_dir(), "*.seg")) |> MapSet.new()
    end

    # Hands off and writes every writable segment the run has so far, so a manager
    # stop in the test (which persists them all on the way down) only has this test's
    # rows left to write. Otherwise the restart's length depends on how many tables
    # earlier tests left and on the host's fsync latency, which made it flaky. The restart loads the written files.
    defp persist_writable_segments do
      registrations = :ets.tab2list(MutableSegments)

      for Registration.tuple(segment: segment, table: table) <- registrations,
          do: :ok = MutableSegments.segment_is_full(table, segment)

      :ok = PersistedSegments.ping()

      # A wait for an outcome: each segment written (or gone), however long the disk
      # takes.
      for Registration.tuple(segment_id: id) <- registrations do
        eventually(
          fn ->
            MutableSegments.get_segment(id) == {:error, :not_found} and
              FullSegments.get_segment(id) == {:error, :not_found}
          end,
          60_000
        )
      end

      :ok
    end

    # Fixtures in every lifecycle state, so each manager has something to own.
    defp fixtures do
      mutable_table = table()
      for v <- 1..20, do: :ok = Guardian.Storage.append(mutable_table, %{"v" => v})
      persisted_table = table()
      {_id, persisted} = persisted_fixture(persisted_table, 1..20)
      full_table = unstorable_table()
      {_id, full} = full_fixture(full_table, 1..20)
      loaded_table = table()
      {_id, loaded, _} = loaded_fixture(loaded_table, 1..20)
      tables = [mutable_table, persisted_table, full_table, loaded_table]
      on_exit(fn -> Enum.each(tables, &Guardian.Storage.delete_table/1) end)

      %{
        tables: %{
          mutable: mutable_table,
          persisted: persisted_table,
          full: full_table,
          loaded: loaded_table,
        },
        segments: [persisted, full, loaded | MutableSegments.get_mutable_segments(mutable_table)],
      }
    end

    # Stopping a manager restarts every later one. The full fixture cannot be stored,
    # so a restart of FullSegments loses it. Stopping FullSegments itself also loses
    # every mutable row, because MutableSegments stops after it and has nowhere to hand
    # its segments. Both are expected; the restart reloads what is on disk.
    for {manager, lost} <- [
          {LoadedSegments, [:full]},
          {FullSegments, [:mutable, :full]},
          {PersistedSegments, []},
          {MutableSegments, []},
        ] do
      test "normally, #{inspect(manager)} leaves no orphaned or duplicate segment" do
        %{tables: tables, segments: segments} = fixtures()
        storage = Process.whereis(Guardian.Storage)
        space_restarts()
        :ok = GenServer.stop(unquote(manager), :normal)
        await_storage_ready()
        assert Process.whereis(Guardian.Storage) == storage
        :ok = PersistedSegments.ping()
        sync()
        :ok = LoadedSegments.rescan()

        for {kind, table} <- tables do
          expected = if Enum.member?(unquote(lost), kind), do: [], else: Enum.to_list(1..20)
          assert {kind, values(table)} == {kind, expected}
        end

        # A segment from before the stop is either gone or owned by a manager.
        for segment <- segments, Process.alive?(segment), do: assert(registered?(segment))
      end
    end

    test "a deletion racing each later manager's stop or crash leaves LoadedSegments up" do
      storage = Process.whereis(Guardian.Storage)

      for manager <- [FullSegments, PersistedSegments, MutableSegments], how <- [:stop, :kill] do
        await_storage_ready()
        loaded = Process.whereis(LoadedSegments)
        table = table()
        {_id, loaded_segment, filename} = loaded_fixture(table, 1..5)
        for v <- 6..10, do: :ok = Guardian.Storage.append(table, %{"v" => v})
        segments = [loaded_segment | MutableSegments.get_mutable_segments(table)]
        space_restarts()

        deletion =
          Task.async(fn ->
            try do
              Guardian.Storage.delete_table(table)
            catch
              # A manager it calls may be restarting.
              _kind, _ -> :failed
            end
          end)

        old = Process.whereis(manager)

        if how == :stop,
          do: GenServer.stop(manager, :normal),
          else: kill(old, :kill)

        # Until the supervisor restarts it, the name may still resolve to the old one.
        eventually(fn -> Process.whereis(manager) not in [nil, old] end)

        Task.await(deletion, 30_000)
        await_storage_ready()
        label = "#{inspect(manager)} #{how}"
        assert {label, Process.whereis(Guardian.Storage)} == {label, storage}
        assert {label, Process.whereis(LoadedSegments)} == {label, loaded}

        # The stopped or killed manager's segments died with it or moved on.
        for segment <- segments,
            Process.alive?(segment),
            do: assert({label, registered?(segment)} == {label, true})

        :ok = Guardian.Storage.delete_table(table)
        refute File.exists?(filename)
        assert values(table) == []
      end
    end
  end

  describe "the persister" do
    test "survives a segment that answers after its call timed out, and persists it later" do
      before = managers()
      table = table()
      persister = Process.whereis(PersistedSegments)
      slow = segment(1..3)
      :ok = :sys.suspend(slow)
      slow_id = Guardian.SegmentID.generate()
      on_exit(fn -> File.rm(Guardian.Storage.SegmentFile.filename(table, slow_id)) end)
      :ok = FullSegments.insert({slow_id, slow, table})
      :ok = PersistedSegments.ping()

      # A second queued freeze means the first call timed out and a later pass tried
      # again. Resumed, the segment answers both calls late, and the persister must
      # survive the stale reply and store the segment.
      eventually(
        fn ->
          {:messages, messages} = Process.info(slow, :messages)
          Enum.count(messages, &match?({:"$gen_call", {^persister, _}, :freeze}, &1)) >= 2
        end,
        15_000
      )

      :ok = :sys.resume(slow)
      eventually(fn -> PersistedSegments.get_segment(slow_id) == {:ok, slow} end, 15_000)
      sync()
      assert managers() == before
      assert values(table) == [1, 2, 3]
      :ok = Guardian.Storage.delete_table(table)
    end

    test "survives a segment that dies during pack, and persists the next one" do
      before = managers()
      table = table()
      persister = Process.whereis(PersistedSegments)
      # The stuck segment answers nothing (suspended before the persister can see it).
      # Once the persister's pack has sent it the first call (`:freeze`), kill it: the
      # call exits and the persister must move on.
      stuck = segment(1..3)
      :ok = :sys.suspend(stuck)
      stuck_id = Guardian.SegmentID.generate()
      on_exit(fn -> File.rm(Guardian.Storage.SegmentFile.filename(table, stuck_id)) end)
      :ok = FullSegments.insert({stuck_id, stuck, table})
      :ok = PersistedSegments.ping()

      eventually(fn ->
        {:messages, messages} = Process.info(stuck, :messages)
        Enum.any?(messages, &match?({:"$gen_call", {^persister, _}, :freeze}, &1))
      end)

      kill(stuck, :kill)

      # Registered after the failure, so only a persister that survived it stores it.
      {next_id, next} = full_fixture(table, 4..6)
      on_exit(fn -> File.rm(Guardian.Storage.SegmentFile.filename(table, next_id)) end)

      # The next pass, after the failed call on the stuck segment.
      eventually(fn -> PersistedSegments.get_segment(next_id) == {:ok, next} end, 15_000)
      sync()
      assert managers() == before
      assert FullSegments.get_segment(stuck_id) == {:error, :not_found}
      assert values(table) == [4, 5, 6]
      :ok = Guardian.Storage.delete_table(table)
    end
  end
end

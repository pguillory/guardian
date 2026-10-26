defmodule Guardian.Counters.RuntimeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Guardian.Test.Polling, only: [eventually: 1]

  @names [
    :counter_runtime_supervisor,
    :counter_runtime_store,
    :counter_runtime_budget,
  ]
  @counters [
    name: :counter_runtime_supervisor,
    store: [name: :counter_runtime_store],
    budget: [name: :counter_runtime_budget],
  ]

  defp start_runtime(opts \\ []) do
    opts = Keyword.merge([name: :counter_runtime_restarter, counters: @counters], opts)

    root =
      start_supervised!(%{
        id: :counter_runtime_parent,
        start:
          {Supervisor, :start_link,
           [
             [{Guardian.Counters.Restarter, opts}, {Task, fn -> Process.sleep(:infinity) end}],
             [strategy: :one_for_one, max_restarts: 1, max_seconds: 5],
           ]},
        type: :supervisor,
      })

    sibling = child(root, Task)
    {root, child(root, Guardian.Counters.Restarter), sibling}
  end

  defp child(supervisor, id) do
    {^id, pid, _, _} = List.keyfind(Supervisor.which_children(supervisor), id, 0)
    pid
  end

  defp crash(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  defp crash_subtree(subtree) do
    crash(subtree)
    # DOWN can precede linked child cleanup. Production retries transient name
    # conflicts with backoff; tests forcing immediate retries must first let the
    # old generation release every registered process/table name.
    eventually(fn ->
      Enum.all?(@names, &(Process.whereis(&1) == nil)) and
        :ets.whereis(:counter_runtime_budget) == :undefined
    end)
  end

  defp await_down(owner) do
    eventually(fn ->
      state = :sys.get_state(owner)
      state.subtree == nil and is_reference(state.retry_timer)
    end)

    :sys.get_state(owner)
  end

  # Exercise real callbacks without sleeping through production backoff minutes.
  defp fire_timer(owner, field, kind) do
    ref = Map.fetch!(:sys.get_state(owner), field)
    assert is_reference(ref)
    Process.cancel_timer(ref)
    send(owner, {:timeout, ref, kind})
    :sys.get_state(owner)
  end

  test "one child failure restarts only that child, preserving siblings and the application supervisor" do
    {root, owner, sibling} = start_runtime()
    subtree = Process.whereis(:counter_runtime_supervisor)

    for {failed, untouched} <- [
          {:counter_runtime_store, :counter_runtime_budget},
          {:counter_runtime_budget, :counter_runtime_store},
        ] do
      old = Process.whereis(failed)
      survivor = Process.whereis(untouched)
      crash(old)
      eventually(fn -> is_pid(Process.whereis(failed)) and Process.whereis(failed) != old end)
      assert Process.whereis(untouched) == survivor
      assert :sys.get_state(owner).subtree == subtree
      assert Process.alive?(root)
      assert Process.alive?(sibling)
      assert Guardian.Counters.Supervisor.available?(@counters)
    end
  end

  test "mixed Store/Budget crash loops exhaust only the counter subtree, then recover" do
    {root, owner, sibling} = start_runtime(initial_delay_ms: 30)

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    subtree = Process.whereis(:counter_runtime_supervisor)
    monitor = Process.monitor(subtree)

    log =
      capture_log([level: :info], fn ->
        for name <- [
              :counter_runtime_store,
              :counter_runtime_budget,
              :counter_runtime_store,
              :counter_runtime_budget,
            ] do
          pid = Process.whereis(name)
          crash(pid)

          eventually(fn ->
            not Process.alive?(subtree) or
              (is_pid(Process.whereis(name)) and Process.whereis(name) != pid)
          end)
        end

        assert_receive {:DOWN, ^monitor, :process, ^subtree, :shutdown}

        eventually(fn ->
          replacement = :sys.get_state(owner).subtree
          is_pid(replacement) and replacement != subtree
        end)
      end)

    assert log =~ "[error] Counters: subtree unavailable (shutdown)"
    assert log =~ "Counters: subtree recovered"
    assert Process.alive?(root)
    assert Process.alive?(owner)
    assert Process.alive?(sibling)
    assert child(root, Guardian.Counters.Restarter) == owner
    assert Guardian.Counters.Supervisor.available?(@counters)
  end

  test "down counters fail open and failed starts double/cap backoff without crashing the owner" do
    {root, owner, sibling} = start_runtime()

    log =
      capture_log(fn ->
        crash_subtree(:sys.get_state(owner).subtree)
        state = await_down(owner)
        refute Guardian.Counters.Supervisor.available?(@counters)
        assert :erlang.read_timer(state.retry_timer) in 1..15_000
        assert state.next_delay == 30_000

        event =
          Guardian.Counters.Client.new_event(Guardian.Counters.Client.new_batch(),
            members: [node()],
            store: :counter_runtime_store,
            cooldown_table: :counter_runtime_budget
          )

        key = {{"events", "hits", "hash"}, {}, 1}

        assert Guardian.Counters.Client.dispatch([{node(), [{:incr, key, 1, 1_000}]}], event) ==
                 [{node(), [{:error, :cooldown}]}]

        # Failed linked starts return a shutdown tuple and may deliver a stray EXIT.
        :sys.replace_state(owner, fn state ->
          put_in(state, [:counters, :store],
            name: :counter_runtime_store,
            memory_budget_bytes: "PRIVATE"
          )
        end)

        for {delay, next_delay} <- [
              {30_000, 60_000},
              {120_000, 240_000},
              {240_000, 240_000},
            ] do
          state = fire_timer(owner, :retry_timer, :retry)
          assert :erlang.read_timer(state.retry_timer) in 1..delay
          assert state.next_delay == next_delay
          assert state.subtree == nil

          if next_delay == 60_000 do
            :sys.replace_state(owner, &%{&1 | counters: @counters})
            recovered = fire_timer(owner, :retry_timer, :retry)
            assert is_pid(recovered.subtree)
            assert recovered.next_delay == 60_000
            crash_subtree(recovered.subtree)
            down = await_down(owner)
            assert :erlang.read_timer(down.retry_timer) in 15_001..60_000
            assert down.next_delay == 120_000
            :sys.replace_state(owner, &%{&1 | counters: state.counters})
          end
        end

        # Exceptions in a start are also scrubbed and retry rather than escaping.
        :sys.replace_state(owner, &%{&1 | counters: [name: "PRIVATE"]})
        assert fire_timer(owner, :retry_timer, :retry).subtree == nil
        :sys.replace_state(owner, &%{&1 | counters: @counters})
        state = fire_timer(owner, :retry_timer, :retry)
        assert is_pid(state.subtree)
        assert state.next_delay == 240_000
        # A short-lived recovery must retain the escalated delay, and its canceled
        # healthy timer must not reset the backoff during the next outage.
        crash_subtree(state.subtree)
        down = await_down(owner)
        assert :erlang.read_timer(down.retry_timer) in 15_001..240_000
        send(owner, {:timeout, state.healthy_timer, :healthy})
        assert :sys.get_state(owner).next_delay == 240_000
        state = fire_timer(owner, :retry_timer, :retry)
        assert is_pid(state.subtree)
        assert :erlang.read_timer(state.healthy_timer) in 1..60_000
        assert fire_timer(owner, :healthy_timer, :healthy).next_delay == 15_000

        # A failure after the healthy interval uses the initial delay again.
        crash_subtree(:sys.get_state(owner).subtree)
        state = await_down(owner)
        assert :erlang.read_timer(state.retry_timer) in 1..15_000
        assert state.next_delay == 30_000
      end)

    refute log =~ "PRIVATE"
    assert log =~ "Counters: subtree unavailable (killed)"
    assert log =~ "Counters: subtree unavailable (start_or_process_failure)"
    for pid <- [root, owner, sibling], do: assert(Process.alive?(pid))
  end

  test "stale timers and exits cannot change another generation's recovery state" do
    {_root, owner, _sibling} = start_runtime()
    old = :sys.get_state(owner)

    capture_log(fn ->
      crash_subtree(old.subtree)
      down = await_down(owner)
      send(owner, {:timeout, old.healthy_timer, :healthy})
      send(owner, {:timeout, nil, :retry})
      send(owner, {:timeout, nil, :healthy})
      send(owner, {:timeout, make_ref(), :retry})
      send(owner, {:EXIT, self(), :unrelated})
      assert :sys.get_state(owner) == down

      recovered = fire_timer(owner, :retry_timer, :retry)
      assert is_pid(recovered.subtree)
      send(owner, {:timeout, down.retry_timer, :retry})
      send(owner, {:timeout, nil, :retry})
      send(owner, {:EXIT, old.subtree, :shutdown})
      assert :sys.get_state(owner) == recovered
    end)
  end

  test "clean owner shutdown after recovery stops all children without a false error" do
    {root, owner, _sibling} = start_runtime()

    capture_log(fn ->
      crash_subtree(:sys.get_state(owner).subtree)
      await_down(owner)
      assert is_pid(fire_timer(owner, :retry_timer, :retry).subtree)
    end)

    pids = for name <- @names, do: Process.whereis(name)

    log =
      capture_log(fn ->
        :ok = Supervisor.terminate_child(root, Guardian.Counters.Restarter)
      end)

    refute log =~ "[error]"
    refute log =~ "Counters: subtree unavailable"
    for pid <- [owner | pids], do: refute(Process.alive?(pid))
    refute Guardian.Counters.Supervisor.available?(@counters)
  end

  test "owner killed during old-subtree teardown retries instead of adopting the old parent" do
    {root, owner, sibling} = start_runtime()
    subtree = :sys.get_state(owner).subtree

    old_children =
      for name <- [:counter_runtime_store, :counter_runtime_budget], do: Process.whereis(name)

    # VM suspension keeps the old generation's names until we release it, even
    # though OTP would handle its parent's EXIT while merely sys-suspended.
    true = :erlang.suspend_process(subtree)

    on_exit(fn ->
      if Process.alive?(subtree) do
        try do
          :erlang.resume_process(subtree)
        catch
          :error, :badarg -> :ok
        end

        Process.exit(subtree, :kill)
      end
    end)

    capture_log(fn ->
      crash(owner)

      eventually(fn ->
        is_pid(Process.whereis(:counter_runtime_restarter)) and
          Process.whereis(:counter_runtime_restarter) != owner
      end)

      replacement = Process.whereis(:counter_runtime_restarter)
      assert await_down(replacement).subtree == nil
      assert Process.alive?(subtree)
      ref = Process.monitor(subtree)
      true = :erlang.resume_process(subtree)
      assert_receive {:DOWN, ^ref, :process, ^subtree, _}
      for pid <- old_children, do: refute(Process.alive?(pid))
      assert is_pid(fire_timer(replacement, :retry_timer, :retry).subtree)
      assert Process.alive?(root)
      assert Process.alive?(sibling)
      assert Guardian.Counters.Supervisor.available?(@counters)
    end)
  end

  test "invalid configured store budget still refuses startup" do
    assert {:error, _} =
             start_supervised(
               {Guardian.Counters.Restarter,
                name: :counter_runtime_restarter,
                counters:
                  Keyword.put(@counters, :store,
                    name: :counter_runtime_store,
                    memory_budget_bytes: 0
                  )}
             )

    for name <- @names, do: assert(Process.whereis(name) == nil)
  end

  test "arbitrary exit details and formatted owner status stay redacted" do
    {_root, owner, _sibling} = start_runtime()
    subtree = :sys.get_state(owner).subtree
    on_exit(fn -> if Process.alive?(subtree), do: Process.exit(subtree, :kill) end)

    log =
      capture_log(fn ->
        send(owner, {:EXIT, subtree, {:unexpected, "PRIVATE"}})
        await_down(owner)
        crash_subtree(subtree)
        assert is_pid(fire_timer(owner, :retry_timer, :retry).subtree)
      end)

    assert log =~ "Counters: subtree unavailable (start_or_process_failure)"
    refute log =~ "PRIVATE"

    formatted =
      Guardian.Counters.Restarter.format_status(%{
        state: "PRIVATE",
        message: "PRIVATE",
        log: ["PRIVATE"],
        reason: "PRIVATE",
      })

    refute inspect(formatted) =~ "PRIVATE"
  end
end

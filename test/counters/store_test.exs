defmodule Guardian.Counters.StoreTest do
  use ExUnit.Case, async: false

  alias Guardian.Counters.Store
  import ExUnit.CaptureLog

  setup do
    clock = :atomics.new(1, [])
    server = start_store(clock)
    %{server: server, clock: clock, opts: [server: server, timeout: 5_000]}
  end

  defp start_store(clock, opts \\ []) do
    start_supervised!(
      {Store, Keyword.merge([name: nil, clock: fn -> :atomics.get(clock, 1) end], opts)},
      id: make_ref()
    )
  end

  test "misses, stored nil, ordered multi-key reads and opaque mutation tokens", %{opts: opts} do
    assert Store.get(:missing, opts) == :not_found
    assert Store.gets(:missing, opts) == :not_found
    assert Store.cas(nil, :missing, nil, 100, opts) == :ok
    assert Store.get(nil, opts) == {:ok, nil}
    assert {:ok, nil, token} = Store.gets(nil, opts)
    assert is_reference(token)

    assert Store.get_many([nil, :missing, nil], opts) ==
             {:ok, [{:ok, nil}, :not_found, {:ok, nil}]}

    assert Store.get_many([], opts) == {:ok, []}
    assert Store.get_many([1, 2, 3, 4, 5], opts) == {:error, :invalid_request}
    assert Store.get_many(:not_a_list, opts) == {:error, :invalid_request}
  end

  test "CAS creates only missing keys and rejects stale or foreign tokens", %{opts: opts} do
    assert Store.cas(:a, make_ref(), 1, 100, opts) == {:error, :conflict}
    assert Store.cas(:a, :missing, 1, 100, opts) == :ok
    assert Store.cas(:a, :missing, 2, 100, opts) == {:error, :conflict}
    assert {:ok, 1, token} = Store.gets(:a, opts)
    assert Store.cas(:b, :missing, 1, 100, opts) == :ok
    assert Store.cas(:b, token, 2, 100, opts) == {:error, :conflict}
    assert Store.cas(:a, token, 2, 100, opts) == :ok
    assert {:ok, 2, replacement} = Store.gets(:a, opts)
    refute replacement == token
    assert Store.cas(:a, token, 3, 100, opts) == {:error, :conflict}
    assert Store.incr(:a, 1, 100, opts) == {:ok, 3}
    assert Store.cas(:a, replacement, 4, 100, opts) == {:error, :conflict}
  end

  test "competing missing-key creates have exactly one winner", %{opts: opts} do
    results =
      1..40
      |> Task.async_stream(fn n -> Store.cas(:race, :missing, n, 100, opts) end,
        max_concurrency: 40
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict})) == 39
  end

  test "increments are atomic, preserve arbitrary store integers, and reject other values", %{
    opts: opts,
  } do
    1..40
    |> Task.async_stream(
      fn _ ->
        for _ <- 1..25, do: assert({:ok, _} = Store.incr(:count, 1, 100, opts))
      end,
      max_concurrency: 40
    )
    |> Enum.each(fn {:ok, _} -> :ok end)

    assert Store.get(:count, opts) == {:ok, 1_000}
    assert Store.incr(:count, -1, 100, opts) == {:ok, 999}

    assert Store.incr(:large, 9_223_372_036_854_775_807, 100, opts) ==
             {:ok, 9_223_372_036_854_775_807}

    assert Store.incr(:large, 1, 100, opts) == {:ok, 9_223_372_036_854_775_808}
    assert Store.cas(:text, :missing, "1", 100, opts) == :ok
    assert Store.incr(:text, 1, 100, opts) == {:error, :not_integer}
    assert Store.get(:text, opts) == {:ok, "1"}
  end

  test "expiry boundary, renewal, no read/conflict refresh, and no stale-token ABA", %{
    opts: opts,
    clock: clock,
  } do
    assert Store.incr(:count, 1, 100, opts) == {:ok, 1}
    assert {:ok, 1, token} = Store.gets(:count, opts)
    :atomics.put(clock, 1, 99)
    assert Store.get(:count, opts) == {:ok, 1}
    assert Store.cas(:count, :missing, 7, 1_000, opts) == {:error, :conflict}
    :atomics.put(clock, 1, 100)
    assert Store.get(:count, opts) == :not_found
    assert Store.cas(:count, token, 2, 100, opts) == {:error, :conflict}
    assert Store.incr(:count, 1, 100, opts) == {:ok, 1}
    assert Store.cas(:count, token, 7, 100, opts) == {:error, :conflict}

    :atomics.put(clock, 1, 150)
    assert Store.incr(:count, 1, 100, opts) == {:ok, 2}
    :atomics.put(clock, 1, 200)
    # A sweep must not remove this key using the replaced expiry index entry.
    send(opts[:server], :sweep)
    assert Store.get(:count, opts) == {:ok, 2}
    assert {:ok, 2, renewed} = Store.gets(:count, opts)
    assert Store.cas(:count, renewed, 3, 200, opts) == :ok
    :atomics.put(clock, 1, 250)
    assert Store.get(:count, opts) == {:ok, 3}
    :atomics.put(clock, 1, 400)
    assert Store.get_many([:count], opts) == {:ok, [:not_found]}
  end

  test "periodic sweep reclaims quiet expired keys in bounded batches", %{clock: clock} do
    server = start_store(clock, sweep_interval_ms: 10)
    opts = [server: server, timeout: 5_000]

    for key <- 1..600, do: assert({:ok, 1} = Store.incr(key, 1, 10, opts))
    :atomics.put(clock, 1, 10)
    assert_eventually(fn -> assert {:ok, %{keys: 0}} = Store.stats(opts) end)

    manual = start_store(clock, sweep_interval_ms: 60_000)
    manual_opts = [server: manual, timeout: 5_000]
    for key <- 1..600, do: assert({:ok, 1} = Store.incr(key, 1, 10, manual_opts))
    :atomics.put(clock, 1, 20)

    for remaining <- [344, 88, 0] do
      send(manual, :sweep)
      assert {:ok, %{keys: ^remaining}} = Store.stats(manual_opts)
    end
  end

  test "one scheduled sweep drains a quiet backlog without waiting between pages", %{clock: clock} do
    server = start_store(clock, sweep_interval_ms: 60_000)
    opts = [server: server, timeout: 5_000]
    for key <- 1..1_000, do: assert({:ok, 1} = Store.incr(key, 1, 10, opts))
    observer = self()

    :ok =
      :sys.install(
        server,
        {fn debug_state, event, _name ->
           case event do
             {:noreply, state} ->
               send(observer, {:page_remaining, :ets.info(state.entries, :size)})

             _ ->
               :ok
           end

           debug_state
         end, nil}
      )

    %{sweep_tag: tag} = :sys.get_state(server)
    :atomics.put(clock, 1, 10)
    send(server, {:sweep, tag})

    for remaining <- [744, 488, 232, 0], do: assert_receive({:page_remaining, ^remaining})
    assert_eventually(fn -> assert {:ok, %{keys: 0}} = Store.stats(opts) end)
    %{sweep_tag: new_tag} = :sys.get_state(server)
    refute new_tag == tag

    assert Store.incr(:new, 1, 10, opts) == {:ok, 1}
    :atomics.put(clock, 1, 20)
    send(server, {:sweep, tag})
    assert {:ok, %{keys: 1}} = Store.stats(opts)
    assert %{sweep_tag: ^new_tag} = :sys.get_state(server)
  end

  test "capacity reclaims all newer expired entries before evicting an older live key", %{
    clock: clock,
  } do
    probe = start_store(clock, sweep_interval_ms: 60_000)
    probe_opts = [server: probe, timeout: 5_000]
    for key <- 0..601, do: assert({:ok, 1} = Store.incr(key, 1, 10_000, probe_opts))
    assert {:ok, %{memory_bytes: budget}} = Store.stats(probe_opts)

    server = start_store(clock, memory_budget_bytes: budget, sweep_interval_ms: 60_000)
    opts = [server: server, timeout: 5_000]
    assert Store.incr(0, 1, 10_000, opts) == {:ok, 1}
    assert {:ok, 1, token} = Store.gets(0, opts)
    for key <- 1..600, do: assert({:ok, 1} = Store.incr(key, 1, 10, opts))
    assert {:ok, %{keys: 601}} = Store.stats(opts)

    :atomics.put(clock, 1, 10)
    assert Store.incr(601, 1, 10_000, opts) == {:ok, 1}
    assert {:ok, %{keys: 2, memory_bytes: bytes}} = Store.stats(opts)
    assert bytes < budget
    assert Store.gets(0, opts) == {:ok, 1, token}
    assert Store.get(601, opts) == {:ok, 1}
    assert Store.get(600, opts) == :not_found
    assert Store.cas(0, token, 2, 10_000, opts) == :ok
  end

  test "budget evicts oldest half, updates stay old, and evicted tokens cannot recreate", %{
    clock: clock,
  } do
    # Measure this VM's entry/index accounting rather than pinning allocator sizes.
    probe = start_store(clock)
    probe_opts = [server: probe, timeout: 5_000]
    for key <- 1..7, do: assert({:ok, 1} = Store.incr(key, 1, 100, probe_opts))
    assert {:ok, %{memory_bytes: budget}} = Store.stats(probe_opts)

    server = start_store(clock, memory_budget_bytes: budget)
    opts = [server: server, timeout: 5_000]
    for key <- 1..6, do: assert({:ok, 1} = Store.incr(key, 1, 100, opts))
    assert {:ok, 1, token} = Store.gets(1, opts)
    assert Store.incr(1, 1, 100, opts) == {:ok, 2}
    assert Store.incr(7, 1, 100, opts) == {:ok, 1}
    assert {:ok, %{keys: keys, memory_bytes: bytes}} = Store.stats(opts)
    assert keys == 3
    assert bytes < budget
    for key <- 1..4, do: assert(Store.get(key, opts) == :not_found)
    for key <- 5..7, do: assert(Store.get(key, opts) == {:ok, 1})
    assert Store.cas(1, token, 7, 100, opts) == {:error, :conflict}

    oldest_update = start_store(clock, memory_budget_bytes: budget)
    update_opts = [server: oldest_update, timeout: 5_000]
    for key <- 1..6, do: assert({:ok, 1} = Store.incr(key, 1, 100, update_opts))
    assert {:ok, 1, update_token} = Store.gets(1, update_opts)

    assert Store.cas(1, update_token, :binary.copy("x", div(budget, 2)), 100, update_opts) ==
             {:error, :evicted}

    assert Store.get(1, update_opts) == :not_found
    assert Store.cas(1, update_token, 7, 100, update_opts) == {:error, :conflict}
    assert Store.incr(1, 1, 100, update_opts) == {:ok, 1}
    assert Store.cas(1, update_token, 7, 100, update_opts) == {:error, :conflict}
    assert Store.incr(1, 1, 100, opts) == {:ok, 1}
    assert Store.cas(1, token, 7, 100, opts) == {:error, :conflict}
  end

  test "large off-heap binaries count toward the budget and oversize replacements are refused", %{
    clock: clock,
  } do
    server = start_store(clock, memory_budget_bytes: 100_000)
    opts = [server: server, timeout: 5_000]
    assert Store.cas(:a, :missing, "old", 100, opts) == :ok
    assert {:ok, "old", token} = Store.gets(:a, opts)
    assert Store.cas(:a, token, :binary.copy("x", 100_000), 100, opts) == {:error, :too_large}
    assert Store.gets(:a, opts) == {:ok, "old", token}
    # The first eviction half contains only small entries, so the large survivors
    # require more than one half-eviction pass to get below the budget.
    for key <- 1..7, do: assert({:ok, 1} = Store.incr(key, 1, 100, opts))
    assert Store.cas(:b, :missing, :binary.copy("x", 60_000), 100, opts) == :ok
    assert {:ok, %{memory_bytes: bytes}} = Store.stats(opts)
    assert bytes >= 60_000 and bytes < 100_000
    assert Store.cas(:c, :missing, :binary.copy("y", 60_000), 100, opts) == :ok
    assert Store.get(:a, opts) == :not_found
    assert Store.get(:b, opts) == :not_found
    assert {:ok, %{keys: 1, memory_bytes: bytes}} = Store.stats(opts)
    assert bytes < 100_000
  end

  test "counter loss and token uniqueness across store restarts", %{opts: opts, clock: clock} do
    assert Store.incr(:key, 1, 100, opts) == {:ok, 1}
    assert {:ok, 1, token} = Store.gets(:key, opts)
    GenServer.stop(opts[:server])
    replacement = start_store(clock)
    replacement_opts = [server: replacement, timeout: 5_000]
    assert Store.get(:key, replacement_opts) == :not_found
    assert Store.cas(:key, token, 1, 100, replacement_opts) == {:error, :conflict}
    assert Store.incr(:key, 1, 100, replacement_opts) == {:ok, 1}
    assert {:ok, 1, fresh} = Store.gets(:key, replacement_opts)
    refute fresh == token
  end

  test "binary slices charge their backing allocation through nested keys and values", %{
    clock: clock,
  } do
    backing = :binary.copy("x", 131_072)
    slice = binary_part(backing, 1, 80)
    <<_::1, bits::bitstring-size(639), _::bitstring>> = backing
    assert :binary.referenced_byte_size(slice) == 131_072
    assert :binary.referenced_byte_size(bits) == 131_072
    server = start_store(clock, memory_budget_bytes: 100_000)
    opts = [server: server, timeout: 5_000]

    # Cover tuple/list/map keys and values, an improper list, non-byte-aligned
    # slices, and a function environment (all of which ETS can retain).
    for value <- [slice, {0, [slice]}, %{slice => true}, [0 | slice], bits, fn -> slice end] do
      assert Store.cas(:key, :missing, value, 100, opts) == {:error, :too_large}
    end

    for key <- [{:group, slice}, %{slice => [0]}, [nil, bits]] do
      assert Store.cas(key, :missing, 1, 100, opts) == {:error, :too_large}
    end

    assert {:ok, %{keys: 0, memory_bytes: 0}} = Store.stats(opts)
    # A detached copy is small and can be stored; no blanket slice-size rejection.
    assert Store.cas(:key, :missing, :binary.copy(slice), 100, opts) == :ok

    roomy = start_store(clock, memory_budget_bytes: 600_000)
    roomy_opts = [server: roomy, timeout: 5_000]
    assert Store.cas(:slice, :missing, slice, 100, roomy_opts) == :ok
    assert {:ok, %{memory_bytes: bytes}} = Store.stats(roomy_opts)
    assert bytes >= :binary.referenced_byte_size(slice)
  end

  test "unavailable owners and queued timeouts are scrubbed and never mutate late", %{
    server: server,
    opts: opts,
  } do
    assert Store.get(:key, server: :counter_store_not_running) == {:error, :unavailable}
    :sys.suspend(server)

    try do
      task =
        Task.async(fn ->
          Store.incr("private-key", 1, 100,
            server: server,
            timeout: 10,
            deadline: System.monotonic_time(:millisecond) + 5_000
          )
        end)

      assert Task.await(task) == {:error, :timeout}
    after
      :sys.resume(server)
    end

    assert Store.get("private-key", opts) == :not_found
    deadline = System.monotonic_time(:millisecond) - 1
    assert Store.incr(:expired, 1, 100, opts ++ [deadline: deadline]) == {:error, :timeout}
    assert Store.get(:expired, opts) == :not_found
  end

  test "invalid operations do not kill the owner or change a key", %{server: server, opts: opts} do
    assert Store.incr(:key, 1, 100, opts) == {:ok, 1}

    for ttl <- [0, -1, nil, "1"] do
      assert Store.incr(:key, 1, ttl, opts) == {:error, :invalid_request}
      assert Store.cas(:key, :missing, 2, ttl, opts) == {:error, :invalid_request}
    end

    assert Store.cas(:key, :bad_token, 2, 100, opts) == {:error, :invalid_request}
    assert Store.incr(:key, 1.5, 100, opts) == {:error, :invalid_request}
    assert GenServer.call(server, {:unexpected, "private"}) == {:error, :invalid_request}
    assert Store.get(:key, opts) == {:ok, 1}
  end

  test "rejects invalid startup settings and values that cannot fit even as the only entry", %{
    clock: clock,
  } do
    assert {:error, _} =
             start_supervised({Store, [name: nil, memory_budget_bytes: 0]}, id: make_ref())

    assert {:error, _} =
             start_supervised({Store, [name: nil, sweep_interval_ms: 0]}, id: make_ref())

    for budget <- [1, 100] do
      server = start_store(clock, memory_budget_bytes: budget)
      assert Store.incr(:key, 1, 100, server: server, timeout: 5_000) == {:error, :too_large}
      assert Store.get(:key, server: server, timeout: 5_000) == :not_found
    end
  end

  test "formatted status and crash formatting redact keys, values, messages and logs", %{
    server: server,
    opts: opts,
  } do
    assert Store.cas("PRIVATE-KEY", :missing, "PRIVATE-VALUE", 100, opts) == :ok
    status = inspect(:sys.get_status(server), limit: :infinity, printable_limit: :infinity)
    refute status =~ "PRIVATE"

    formatted =
      Store.format_status(%{
        state: %{secret: "PRIVATE"},
        message: {:cas, "PRIVATE"},
        log: [{:in, "PRIVATE"}],
        reason: {:badarg, "PRIVATE"},
      })

    refute inspect(formatted) =~ "PRIVATE"
  end

  test "an actual callback crash scrubs payloads and the supervised store restarts empty", %{
    clock: clock,
  } do
    fail = :atomics.new(1, [])

    server =
      start_store(clock,
        name: :counter_store_crash_test,
        clock: fn ->
          if :atomics.get(fail, 1) == 1, do: raise("PRIVATE-CLOCK")
          :atomics.get(clock, 1)
        end
      )

    opts = [server: :counter_store_crash_test, timeout: 5_000]
    assert Store.cas("PRIVATE-KEY", :missing, "PRIVATE-VALUE", 100, opts) == :ok
    monitor = Process.monitor(server)

    log =
      capture_log(fn ->
        :atomics.put(fail, 1, 1)
        assert Store.get("PRIVATE-KEY", opts) == {:error, :unavailable}
        assert_receive {:DOWN, ^monitor, :process, ^server, reason}
        refute inspect(reason) =~ "PRIVATE"
        :atomics.put(fail, 1, 0)

        assert_eventually(fn ->
          replacement = Process.whereis(:counter_store_crash_test)
          assert is_pid(replacement) and replacement != server
          assert Store.get("PRIVATE-KEY", opts) == :not_found
        end)
      end)

    assert log =~ ":redacted"
    refute log =~ "PRIVATE"
  end

  defp assert_eventually(assertion, left \\ 100)
  defp assert_eventually(assertion, 0), do: assertion.()

  defp assert_eventually(assertion, left) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      assert_eventually(assertion, left - 1)
  end
end

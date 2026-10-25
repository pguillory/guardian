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

  test "misses, stored nil and opaque mutation tokens", %{opts: opts} do
    assert {:ok, %{keys: 0, memory_bytes: 0}} = Store.stats(opts)
    assert Store.get(:missing, opts) == :not_found
    assert Store.gets(:missing, opts) == :not_found
    assert Store.cas(nil, :missing, nil, 100, opts) == :ok
    assert Store.get(nil, opts) == {:ok, nil}
    assert {:ok, nil, token} = Store.gets(nil, opts)
    assert {table, version} = token
    assert is_reference(table) and is_integer(version)
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
    assert {:ok, 3, before_zero} = Store.gets(:a, opts)
    assert Store.incr(:a, 0, 100, opts) == {:ok, 3}
    assert Store.cas(:a, before_zero, 4, 100, opts) == {:error, :conflict}
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

  test "live CAS contenders and expired missing-key contenders each have one winner", %{
    opts: opts,
    clock: clock,
  } do
    Store.cas(:race, :missing, nil, 10, opts)
    assert {:ok, nil, token} = Store.gets(:race, opts)

    for expected <- [token, :missing] do
      if expected == :missing, do: :atomics.put(clock, 1, 10)

      results =
        1..40
        |> Task.async_stream(fn n -> Store.cas(:race, expected, n, 100, opts) end,
          max_concurrency: 40
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :conflict})) == 39
    end
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

  test "fixed expiry, expired integer/noninteger reuse, and stale token rejection", %{
    opts: opts,
    clock: clock,
  } do
    assert Store.incr(:count, 1, 100, opts) == {:ok, 1}
    assert {:ok, 1, token} = Store.gets(:count, opts)
    :atomics.put(clock, 1, 50)
    assert Store.incr(:count, 1, 1000, opts) == {:ok, 2}
    assert {:ok, 2, current} = Store.gets(:count, opts)
    assert Store.cas(:count, current, 3, 1000, opts) == :ok
    :atomics.put(clock, 1, 100)
    assert Store.get(:count, opts) == :not_found
    assert Store.cas(:count, token, 9, 100, opts) == {:error, :conflict}
    assert Store.incr(:count, 1, 100, opts) == {:ok, 1}
    assert Store.cas(:count, current, 9, 100, opts) == {:error, :conflict}
    assert Store.cas(:text, :missing, "old", 10, opts) == :ok
    :atomics.put(clock, 1, 110)
    assert Store.incr(:text, 1, 100, opts) == {:ok, 1}
    assert Store.cas(:other, :missing, nil, 10, opts) == :ok
    :atomics.put(clock, 1, 120)
    assert Store.cas(:other, :missing, "new", 100, opts) == :ok
  end

  test "concurrent expired-key reuse preserves every live increment", %{opts: opts, clock: clock} do
    Store.incr(:expired, 99, 10, opts)
    :atomics.put(clock, 1, 10)

    1..40
    |> Task.async_stream(fn _ -> Store.incr(:expired, 1, 100, opts) end, max_concurrency: 40)
    |> Enum.each(fn {:ok, {:ok, _}} -> :ok end)

    assert Store.get(:expired, opts) == {:ok, 40}
  end

  test "bulk expiry and stale tags retain a single periodic timer chain", %{clock: clock} do
    server = start_store(clock, sweep_interval_ms: 60_000)
    opts = [server: server, timeout: 5000]
    for key <- 1..1000, do: assert({:ok, 1} = Store.incr(key, 1, 10, opts))
    %{sweep_tag: tag} = :sys.get_state(server)
    :atomics.put(clock, 1, 10)
    send(server, {:sweep, tag})
    %{sweep_tag: new_tag} = :sys.get_state(server)
    assert tag != new_tag
    assert {:ok, %{keys: 0}} = Store.stats(opts)
    Store.incr(:new, 1, 10, opts)
    :atomics.put(clock, 1, 20)
    send(server, {:sweep, tag})
    assert %{sweep_tag: ^new_tag} = :sys.get_state(server)
    assert {:ok, %{keys: 1}} = Store.stats(opts)
    send(server, :sweep)
    :sys.get_state(server)
    assert {:ok, %{keys: 0}} = Store.stats(opts)
    periodic = start_store(clock, sweep_interval_ms: 10)
    Store.incr(:quiet, 1, 10, server: periodic)
    :atomics.put(clock, 1, 30)
    assert_eventually(fn -> assert {:ok, %{keys: 0}} = Store.stats(server: periodic) end)
  end

  test "expiry precedes capacity reclamation and writes do not run eviction", %{clock: clock} do
    server = start_store(clock, memory_budget_bytes: 100_000, sweep_interval_ms: 60_000)
    opts = [server: server, timeout: 5000]
    assert Store.cas(:live, :missing, :binary.copy("x", 60_000), 1000, opts) == :ok
    assert {:ok, _, token} = Store.gets(:live, opts)
    assert Store.cas(:short, :missing, :binary.copy("y", 60_000), 10, opts) == :ok
    assert {:ok, %{keys: 2, memory_bytes: bytes}} = Store.stats(opts)
    assert bytes > 100_000
    :atomics.put(clock, 1, 10)
    send(server, :sweep)
    :sys.get_state(server)
    assert {:ok, %{keys: 1, memory_bytes: bytes}} = Store.stats(opts)
    assert bytes < 100_000
    assert {:ok, _, ^token} = Store.gets(:live, opts)
  end

  test "capacity cutoff removes earliest-expiring buckets, including tied expiry", %{clock: clock} do
    server = start_store(clock, memory_budget_bytes: 100_000, sweep_interval_ms: 60_000)
    opts = [server: server, timeout: 5000]
    # Insert the later expiry first: eviction follows expiry, not insertion order.
    Store.cas(:later, :missing, :binary.copy("x", 40_000), 1000, opts)
    Store.cas(:earlier, :missing, :binary.copy("x", 40_000), 100, opts)
    assert {:ok, _, token} = Store.gets(:earlier, opts)
    Store.cas(:middle, :missing, :binary.copy("x", 40_000), 500, opts)
    send(server, :sweep)
    :sys.get_state(server)
    assert Store.get(:earlier, opts) == :not_found
    assert {:ok, _} = Store.get(:later, opts)
    assert Store.cas(:earlier, token, 7, 100, opts) == {:error, :conflict}
    assert {:ok, %{memory_bytes: bytes}} = Store.stats(opts)
    assert bytes < 100_000
    Store.incr(:earlier, 1, 100, opts)
    assert Store.cas(:earlier, token, 7, 100, opts) == {:error, :conflict}
    for key <- 1..5, do: Store.cas(key, :missing, :binary.copy("x", 40_000), 1000, opts)
    send(server, :sweep)
    :sys.get_state(server)
    assert {:ok, %{keys: 0}} = Store.stats(opts)
  end

  test "large values are charged and oversize replacement preserves the old value", %{
    clock: clock,
  } do
    server = start_store(clock, memory_budget_bytes: 100_000)
    opts = [server: server, timeout: 5000]
    Store.cas(:a, :missing, "old", 100, opts)
    assert {:ok, "old", token} = Store.gets(:a, opts)
    assert Store.cas(:a, token, :binary.copy("x", 100_000), 100, opts) == {:error, :too_large}
    assert Store.gets(:a, opts) == {:ok, "old", token}
    assert Store.cas(:b, :missing, :binary.copy("x", 60_000), 100, opts) == :ok
    assert {:ok, %{memory_bytes: bytes}} = Store.stats(opts)
    assert bytes >= 60_000
  end

  test "large survivors require multiple passes and immediate continuation ticks", %{clock: clock} do
    server = start_store(clock, memory_budget_bytes: 100_000, sweep_interval_ms: 60_000)
    opts = [server: server, timeout: 5000]
    for key <- 1..4096, do: Store.incr(key, 1, 10_000 + key, opts)

    for key <- 4097..4099,
        do: assert(Store.cas(key, :missing, :binary.copy("x", 40_000), 10_000 + key, opts) == :ok)

    observer = self()

    :sys.install(
      server,
      {fn debug, event, _ ->
         if match?({:noreply, _}, event), do: send(observer, :sweep_turn)
         debug
       end, nil}
    )

    %{sweep_tag: tag} = :sys.get_state(server)
    send(server, {:sweep, tag})
    # More than four median-cutoff passes are needed to reach the three largest
    # expiry keys. The next tick must run immediately, not after the 60s interval.
    assert_receive :sweep_turn
    assert_receive :sweep_turn

    assert_eventually(fn ->
      assert {:ok, %{memory_bytes: bytes}} = Store.stats(opts)
      assert bytes < 100_000
    end)
  end

  test "a caller clock exception is scrubbed without crashing the owner", %{clock: clock} do
    fail = :atomics.new(1, [])

    server =
      start_store(clock,
        clock: fn ->
          if :atomics.get(fail, 1) == 1, do: raise("PRIVATE-CLOCK")
          :atomics.get(clock, 1)
        end
      )

    log =
      capture_log(fn ->
        :atomics.put(fail, 1, 1)
        assert Store.get("PRIVATE-KEY", server: server) == {:error, :unavailable}
        :atomics.put(fail, 1, 0)
      end)

    assert Process.alive?(server)
    refute log =~ "PRIVATE"
  end

  test "opaque keys and replacement values cannot act as match patterns", %{opts: opts} do
    keys = [:"$1", :_, {:const, :"$2"}, %{a: :"$1"}, %{a: :"$1", b: 2}, 1, 1.0, 0.0, -0.0]

    for {key, n} <- Enum.with_index(keys) do
      assert Store.cas(key, :missing, n, 100, opts) == :ok
    end

    for {key, n} <- Enum.with_index(keys) do
      assert {:ok, ^n, token} = Store.gets(key, opts)
      assert Store.cas(key, token, {:"$1", %{a: :_}}, 100, opts) == :ok
      assert Store.get(key, opts) == {:ok, {:"$1", %{a: :_}}}
    end

    first = Map.new([{"a", 1}, {"b", 2}])
    second = Map.new([{"b", 2}, {"a", 1}])
    assert Store.incr(first, 1, 100, opts) == {:ok, 1}
    assert Store.incr(second, 1, 100, opts) == {:ok, 2}
  end

  test "housekeeper suspension cannot block callers, including named lookup", %{
    server: server,
    opts: opts,
    clock: clock,
  } do
    named = start_store(clock, name: :counter_direct_test)

    for {owner, options} <- [{server, opts}, {named, [server: :counter_direct_test]}] do
      :sys.suspend(owner)

      try do
        assert Store.incr(:direct, 1, 100, options) == {:ok, 1}
        assert {:ok, 1, token} = Store.gets(:direct, options)
        assert Store.cas(:direct, token, 2, 100, options) == :ok
        assert Store.batch([{:get, :direct}], options) == {:ok, [{:ok, 2}]}
      after
        :sys.resume(owner)
      end
    end
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

  test "a captured table reference cannot address a same-name replacement", %{clock: clock} do
    owner = start_store(clock, name: :counter_generation_test)
    assert Store.incr(:key, 1, 100, server: :counter_generation_test) == {:ok, 1}
    %{entries: old_table} = :sys.get_state(owner)
    GenServer.stop(owner)

    assert_eventually(fn ->
      replacement = Process.whereis(:counter_generation_test)
      assert is_pid(replacement) and replacement != owner
    end)

    assert Store.incr(:key, 1, 100, server: old_table) == {:error, :unavailable}
    assert Store.get(:key, server: :counter_generation_test) == :not_found
  end

  test "value slices charge backing allocations while encoded keys detach them", %{
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
      assert Store.cas(key, :missing, 1, 100, opts) == :ok
      assert {:ok, 1} = Store.get(key, opts)
    end

    assert {:ok, %{memory_bytes: encoded_bytes}} = Store.stats(opts)
    assert encoded_bytes < 100_000
    %{entries: entries} = :sys.get_state(server)

    for {encoded_key, _, _, _} <- :ets.tab2list(entries),
        do: assert(:binary.referenced_byte_size(encoded_key) < 1_000)

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
    pause = Guardian.CounterStoreProbe.pause(server)

    try do
      task =
        Task.async(fn ->
          Store.incr("private-key", 1, 100,
            server: server,
            timeout: 10,
            deadline: System.monotonic_time(:millisecond) + 5_000
          )
        end)

      Guardian.TestHelpers.await_queued_call(elem(pause, 0))
      Process.sleep(20)
      Guardian.CounterStoreProbe.resume(pause)
      assert Task.await(task) == {:error, :timeout}
    after
      if Process.alive?(elem(pause, 0)), do: Guardian.CounterStoreProbe.resume(pause)
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
        send(server, :sweep)
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

  defp assert_eventually(assertion, 0) do
    assertion.()
  end

  defp assert_eventually(assertion, left) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      assert_eventually(assertion, left - 1)
  end
end

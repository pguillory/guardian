defmodule Guardian.Counters.StoreTest do
  use ExUnit.Case, async: false
  import Guardian.Counters.Store

  alias Guardian.Counters.Store
  import ExUnit.CaptureLog

  # Operations take `now` as data, anchored on the live monotonic clock so the real
  # housekeeping sweep agrees with the test about what has expired. The shared store
  # Stores never sweep on their own unless a test asks for an interval.
  setup do
    server = start_store([])
    now = System.monotonic_time(:millisecond)
    %{server: server, now: now, base: now, opts: [server: server, timeout: 5_000]}
  end

  defp start_store(opts) do
    start_supervised!(
      {Store, Keyword.merge([name: nil, sweep_interval_ms: 3_600_000], opts)},
      id: make_ref()
    )
  end

  test "misses, stored nil and opaque mutation tokens", %{now: now, opts: opts} do
    assert {:ok, %{keys: 0, memory_bytes: 0}} = stats(opts)
    assert get(:missing, now, opts) == :not_found
    assert gets(:missing, now, opts) == :not_found
    assert cas(nil, :missing, nil, 100, now, opts) == :ok
    assert get(nil, now, opts) == {:ok, nil}
    assert {:ok, nil, token} = gets(nil, now, opts)
    assert {table, version} = token
    assert is_reference(table) and is_integer(version)
  end

  test "CAS creates only missing keys and rejects stale or foreign tokens", %{
    now: now,
    opts: opts,
  } do
    assert cas(:a, make_ref(), 1, 100, now, opts) == {:error, :conflict}
    assert cas(:a, :missing, 1, 100, now, opts) == :ok
    assert cas(:a, :missing, 2, 100, now, opts) == {:error, :conflict}
    assert {:ok, 1, token} = gets(:a, now, opts)
    assert cas(:b, :missing, 1, 100, now, opts) == :ok
    assert cas(:b, token, 2, 100, now, opts) == {:error, :conflict}
    assert cas(:a, token, 2, 100, now, opts) == :ok
    assert {:ok, 2, replacement} = gets(:a, now, opts)
    refute replacement == token
    assert cas(:a, token, 3, 100, now, opts) == {:error, :conflict}
    assert incr(:a, 1, 100, now, opts) == {:ok, 3}
    assert cas(:a, replacement, 4, 100, now, opts) == {:error, :conflict}
    assert {:ok, 3, before_zero} = gets(:a, now, opts)
    assert incr(:a, 0, 100, now, opts) == {:ok, 3}
    assert cas(:a, before_zero, 4, 100, now, opts) == {:error, :conflict}
  end

  test "competing missing-key creates have exactly one winner", %{now: now, opts: opts} do
    results =
      1..40
      |> Task.async_stream(fn n -> cas(:race, :missing, n, 100, now, opts) end,
        max_concurrency: 40
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict})) == 39
  end

  test "live CAS contenders and expired missing-key contenders each have one winner", %{
    now: now,
    base: base,
    opts: opts,
  } do
    cas(:race, :missing, nil, 10, now, opts)
    assert {:ok, nil, token} = gets(:race, now, opts)

    for expected <- [token, :missing] do
      now = if expected == :missing, do: base + 10, else: now

      results =
        1..40
        |> Task.async_stream(fn n -> cas(:race, expected, n, 100, now, opts) end,
          max_concurrency: 40
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :conflict})) == 39
    end
  end

  test "increments are atomic, preserve arbitrary store integers, and reject other values", %{
    now: now,
    opts: opts,
  } do
    1..40
    |> Task.async_stream(
      fn _ ->
        for _ <- 1..25, do: assert({:ok, _} = incr(:count, 1, 100, now, opts))
      end,
      max_concurrency: 40
    )
    |> Enum.each(fn {:ok, _} -> :ok end)

    assert get(:count, now, opts) == {:ok, 1_000}
    assert incr(:count, -1, 100, now, opts) == {:ok, 999}

    assert incr(:large, 9_223_372_036_854_775_807, 100, now, opts) ==
             {:ok, 9_223_372_036_854_775_807}

    assert incr(:large, 1, 100, now, opts) == {:ok, 9_223_372_036_854_775_808}
    assert cas(:text, :missing, "1", 100, now, opts) == :ok
    assert incr(:text, 1, 100, now, opts) == {:error, :not_integer}
    assert get(:text, now, opts) == {:ok, "1"}
  end

  test "fixed expiry, expired integer/noninteger reuse, and stale token rejection", %{
    now: now,
    base: base,
    opts: opts,
  } do
    assert incr(:count, 1, 100, now, opts) == {:ok, 1}
    assert {:ok, 1, token} = gets(:count, now, opts)
    now = base + 50
    assert incr(:count, 1, 1000, now, opts) == {:ok, 2}
    assert {:ok, 2, current} = gets(:count, now, opts)
    assert cas(:count, current, 3, 1000, now, opts) == :ok
    now = base + 100
    assert get(:count, now, opts) == :not_found
    assert cas(:count, token, 9, 100, now, opts) == {:error, :conflict}
    assert incr(:count, 1, 100, now, opts) == {:ok, 1}
    assert cas(:count, current, 9, 100, now, opts) == {:error, :conflict}
    assert cas(:text, :missing, "old", 10, now, opts) == :ok
    now = base + 110
    assert incr(:text, 1, 100, now, opts) == {:ok, 1}
    assert cas(:other, :missing, nil, 10, now, opts) == :ok
    now = base + 120
    assert cas(:other, :missing, "new", 100, now, opts) == :ok
  end

  test "concurrent expired-key reuse preserves every live increment", %{
    now: now,
    base: base,
    opts: opts,
  } do
    incr(:expired, 99, 10, now, opts)
    now = base + 10

    1..40
    |> Task.async_stream(fn _ -> incr(:expired, 1, 100, now, opts) end, max_concurrency: 40)
    |> Enum.each(fn {:ok, {:ok, _}} -> :ok end)

    assert get(:expired, now, opts) == {:ok, 40}
  end

  # The sweep reads the live clock: rows written with a `now` a minute ago and a
  # short TTL are already expired by it, and rows written now with a long TTL are not.
  test "bulk expiry and stale tags retain a single periodic timer chain", %{now: now} do
    past = now - 60_000
    server = start_store(sweep_interval_ms: 60_000)
    opts = [server: server, timeout: 5000]
    for key <- 1..1000, do: assert({:ok, 1} = incr(key, 1, 10, past, opts))
    %{sweep_tag: tag} = :sys.get_state(server)
    send(server, {:sweep, tag})
    %{sweep_tag: new_tag} = :sys.get_state(server)
    assert tag != new_tag
    assert {:ok, %{keys: 0}} = stats(opts)
    incr(:new, 1, 10, past, opts)
    send(server, {:sweep, tag})
    assert %{sweep_tag: ^new_tag} = :sys.get_state(server)
    assert {:ok, %{keys: 1}} = stats(opts)
    send(server, :sweep)
    :sys.get_state(server)
    assert {:ok, %{keys: 0}} = stats(opts)
    periodic = start_store(sweep_interval_ms: 10)
    incr(:quiet, 1, 10, past, server: periodic, timeout: 5000)
    assert_eventually(fn -> assert {:ok, %{keys: 0}} = stats(server: periodic) end)
  end

  test "expiry precedes capacity reclamation and writes do not run eviction", %{now: now} do
    server = start_store(memory_budget_bytes: 100_000, sweep_interval_ms: 60_000)
    opts = [server: server, timeout: 5000]
    assert cas(:live, :missing, :binary.copy("x", 60_000), 600_000, now, opts) == :ok
    assert {:ok, _, token} = gets(:live, now, opts)
    assert cas(:short, :missing, :binary.copy("y", 60_000), 10, now - 60_000, opts) == :ok
    assert {:ok, %{keys: 2, memory_bytes: bytes}} = stats(opts)
    assert bytes > 100_000
    send(server, :sweep)
    :sys.get_state(server)
    assert {:ok, %{keys: 1, memory_bytes: bytes}} = stats(opts)
    assert bytes < 100_000
    assert {:ok, _, ^token} = gets(:live, now, opts)
  end

  test "capacity cutoff removes earliest-expiring buckets, including tied expiry", %{now: now} do
    server = start_store(memory_budget_bytes: 100_000, sweep_interval_ms: 60_000)
    opts = [server: server, timeout: 5000]
    # Insert the later expiry first: eviction follows expiry, not insertion order.
    # TTLs long enough that the live sweep only evicts, never expires.
    cas(:later, :missing, :binary.copy("x", 40_000), 1_000_000, now, opts)
    cas(:earlier, :missing, :binary.copy("x", 40_000), 100_000, now, opts)
    assert {:ok, _, token} = gets(:earlier, now, opts)
    cas(:middle, :missing, :binary.copy("x", 40_000), 500_000, now, opts)
    send(server, :sweep)
    :sys.get_state(server)
    assert get(:earlier, now, opts) == :not_found
    assert {:ok, _} = get(:later, now, opts)
    assert cas(:earlier, token, 7, 100, now, opts) == {:error, :conflict}
    assert {:ok, %{memory_bytes: bytes}} = stats(opts)
    assert bytes < 100_000
    incr(:earlier, 1, 100, now, opts)
    assert cas(:earlier, token, 7, 100, now, opts) == {:error, :conflict}
    for key <- 1..5, do: cas(key, :missing, :binary.copy("x", 40_000), 1_000_000, now, opts)
    send(server, :sweep)
    :sys.get_state(server)
    assert {:ok, %{keys: 0}} = stats(opts)
  end

  test "large values are charged and oversize replacement preserves the old value", %{now: now} do
    server = start_store(memory_budget_bytes: 100_000)
    opts = [server: server, timeout: 5000]
    cas(:a, :missing, "old", 100, now, opts)
    assert {:ok, "old", token} = gets(:a, now, opts)
    assert cas(:a, token, :binary.copy("x", 100_000), 100, now, opts) == {:error, :too_large}
    assert gets(:a, now, opts) == {:ok, "old", token}
    assert cas(:b, :missing, :binary.copy("x", 60_000), 100, now, opts) == :ok
    assert {:ok, %{memory_bytes: bytes}} = stats(opts)
    assert bytes >= 60_000
  end

  test "large survivors require multiple passes and immediate continuation ticks", %{now: now} do
    server = start_store(memory_budget_bytes: 100_000, sweep_interval_ms: 60_000)
    opts = [server: server, timeout: 5000]
    for key <- 1..4096, do: incr(key, 1, 600_000 + key, now, opts)

    for key <- 4097..4099,
        do: assert(cas(key, :missing, :binary.copy("x", 40_000), 600_000 + key, now, opts) == :ok)

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
      assert {:ok, %{memory_bytes: bytes}} = stats(opts)
      assert bytes < 100_000
    end)
  end

  test "a failing operation is scrubbed, fails alone and spares the owner", %{
    now: now,
    server: server,
    opts: opts,
  } do
    # A descriptor whose table is not a table makes every operation raise inside it.
    restore = Guardian.Test.Counters.StorePause.break_entries(server, "PRIVATE-TABLE")

    log =
      capture_log(fn ->
        try do
          assert get("PRIVATE-KEY", now, opts) == {:error, :unavailable}

          assert batch([{:get, "PRIVATE-KEY"}, {:incr, "PRIVATE-KEY", 1, 100}], now, opts) ==
                   {:ok, [{:error, :unavailable}, {:error, :unavailable}]}
        after
          restore.()
        end
      end)

    assert Process.alive?(server)
    refute log =~ "PRIVATE"
    assert incr("PRIVATE-KEY", 1, 100, now, opts) == {:ok, 1}
  end

  test "opaque keys and replacement values cannot act as match patterns", %{now: now, opts: opts} do
    keys = [:"$1", :_, {:const, :"$2"}, %{a: :"$1"}, %{a: :"$1", b: 2}, 1, 1.0, 0.0, -0.0]

    for {key, n} <- Enum.with_index(keys) do
      assert cas(key, :missing, n, 100, now, opts) == :ok
    end

    for {key, n} <- Enum.with_index(keys) do
      assert {:ok, ^n, token} = gets(key, now, opts)
      assert cas(key, token, {:"$1", %{a: :_}}, 100, now, opts) == :ok
      assert get(key, now, opts) == {:ok, {:"$1", %{a: :_}}}
    end

    first = Map.new([{"a", 1}, {"b", 2}])
    second = Map.new([{"b", 2}, {"a", 1}])
    assert incr(first, 1, 100, now, opts) == {:ok, 1}
    assert incr(second, 1, 100, now, opts) == {:ok, 2}
  end

  test "housekeeper suspension cannot block callers, including named lookup", %{
    now: now,
    server: server,
    opts: opts,
  } do
    named = start_store(name: :counter_direct_test)

    for {owner, options} <- [{server, opts}, {named, [server: :counter_direct_test]}] do
      :sys.suspend(owner)

      try do
        assert incr(:direct, 1, 100, now, options) == {:ok, 1}
        assert {:ok, 1, token} = gets(:direct, now, options)
        assert cas(:direct, token, 2, 100, now, options) == :ok
        assert batch([{:get, :direct}], now, options) == {:ok, [{:ok, 2}]}
      after
        :sys.resume(owner)
      end
    end
  end

  test "counter loss and token uniqueness across store restarts", %{now: now, opts: opts} do
    assert incr(:key, 1, 100, now, opts) == {:ok, 1}
    assert {:ok, 1, token} = gets(:key, now, opts)
    GenServer.stop(opts[:server])
    replacement = start_store([])
    replacement_opts = [server: replacement, timeout: 5_000]
    assert get(:key, now, replacement_opts) == :not_found
    assert cas(:key, token, 1, 100, now, replacement_opts) == {:error, :conflict}
    assert incr(:key, 1, 100, now, replacement_opts) == {:ok, 1}
    assert {:ok, 1, fresh} = gets(:key, now, replacement_opts)
    refute fresh == token
  end

  test "a captured table reference cannot address a same-name replacement", %{now: now} do
    owner = start_store(name: :counter_generation_test)
    assert incr(:key, 1, 100, now, server: :counter_generation_test) == {:ok, 1}
    %{entries: old_table} = :sys.get_state(owner)
    GenServer.stop(owner)

    assert_eventually(fn ->
      replacement = Process.whereis(:counter_generation_test)
      assert is_pid(replacement) and replacement != owner
    end)

    assert incr(:key, 1, 100, now, server: old_table) == {:error, :unavailable}
    assert get(:key, now, server: :counter_generation_test) == :not_found
  end

  test "value slices charge backing allocations while encoded keys detach them", %{now: now} do
    backing = :binary.copy("x", 131_072)
    slice = binary_part(backing, 1, 80)
    <<_::1, bits::bitstring-size(639), _::bitstring>> = backing
    assert :binary.referenced_byte_size(slice) == 131_072
    assert :binary.referenced_byte_size(bits) == 131_072
    server = start_store(memory_budget_bytes: 100_000)
    opts = [server: server, timeout: 5_000]

    # Cover tuple/list/map keys and values, an improper list, non-byte-aligned
    # slices, and a function environment (all of which ETS can retain).
    for value <- [slice, {0, [slice]}, %{slice => true}, [0 | slice], bits, fn -> slice end] do
      assert cas(:key, :missing, value, 100, now, opts) == {:error, :too_large}
    end

    for key <- [{:group, slice}, %{slice => [0]}, [nil, bits]] do
      assert cas(key, :missing, 1, 100, now, opts) == :ok
      assert {:ok, 1} = get(key, now, opts)
    end

    assert {:ok, %{memory_bytes: encoded_bytes}} = stats(opts)
    assert encoded_bytes < 100_000
    %{entries: entries} = :sys.get_state(server)

    for {encoded_key, _, _, _} <- :ets.tab2list(entries),
        do: assert(:binary.referenced_byte_size(encoded_key) < 1_000)

    # A detached copy is small and can be stored; no blanket slice-size rejection.
    assert cas(:key, :missing, :binary.copy(slice), 100, now, opts) == :ok

    roomy = start_store(memory_budget_bytes: 600_000)
    roomy_opts = [server: roomy, timeout: 5_000]
    assert cas(:slice, :missing, slice, 100, now, roomy_opts) == :ok
    assert {:ok, %{memory_bytes: bytes}} = stats(roomy_opts)
    assert bytes >= :binary.referenced_byte_size(slice)
  end

  test "unavailable owners and expired deadlines are scrubbed and never mutate", %{
    now: now,
    opts: opts,
  } do
    assert get(:key, now, server: :counter_store_not_running) == {:error, :unavailable}
    # A caller queued past its deadline is covered through Transport, whose deadline
    # is anchored before `Guardian.Test.Counters.StorePause`'s gate (client_test).
    deadline = System.monotonic_time(:millisecond) - 1
    assert incr(:expired, 1, 100, now, opts ++ [deadline: deadline]) == {:error, :timeout}
    assert get(:expired, now, opts) == :not_found
  end

  test "invalid operations do not kill the owner or change a key", %{
    now: now,
    server: server,
    opts: opts,
  } do
    assert incr(:key, 1, 100, now, opts) == {:ok, 1}

    for ttl <- [0, -1, nil, "1"] do
      assert incr(:key, 1, ttl, now, opts) == {:error, :invalid_request}
      assert cas(:key, :missing, 2, ttl, now, opts) == {:error, :invalid_request}
    end

    assert cas(:key, :bad_token, 2, 100, now, opts) == {:error, :invalid_request}
    assert incr(:key, 1.5, 100, now, opts) == {:error, :invalid_request}
    assert GenServer.call(server, {:unexpected, "private"}) == {:error, :invalid_request}
    assert get(:key, now, opts) == {:ok, 1}
  end

  test "malformed request options are invalid requests", %{now: now, server: server, opts: opts} do
    deadline = System.monotonic_time(:millisecond) + 5_000

    malformed =
      [:bad, [:bad], [{"server", server}], [{:server, server} | :tail]] ++
        for timeout <- [nil, "50", 1.0, 0, -1],
            extra <- [[], [deadline: deadline]],
            do: [server: server, timeout: timeout] ++ extra

    for request_opts <- malformed ++ [[server: server, deadline: nil]] do
      assert get(:key, now, request_opts) == {:error, :invalid_request}, inspect(request_opts)
      assert incr(:key, 1, 100, now, request_opts) == {:error, :invalid_request}
    end

    for bad_now <- [nil, 1.0, "1"] do
      assert get(:key, bad_now, opts) == {:error, :invalid_request}
      assert incr(:key, 1, 100, bad_now, opts) == {:error, :invalid_request}
    end

    assert get(:key, now, opts) == :not_found
  end

  test "a batch judges and sets every expiry as of its one `now`", %{now: now, opts: opts} do
    # A minute ago on the live clock: each row is live as of the batch's `now`, though
    # long expired by the time later operations run.
    past = now - 60_000

    assert batch([{:incr, :a, 1, 10}, {:get, :a}, {:incr, :a, 1, 10}], past, opts) ==
             {:ok, [{:ok, 1}, {:ok, 1}, {:ok, 2}]}

    assert get(:a, past + 9, opts) == {:ok, 2}
    assert get(:a, past + 10, opts) == :not_found
  end

  test "rejects invalid startup settings and values that cannot fit even as the only entry", %{
    now: now,
  } do
    assert {:error, _} =
             start_supervised({Store, [name: nil, memory_budget_bytes: 0]}, id: make_ref())

    assert {:error, _} =
             start_supervised({Store, [name: nil, sweep_interval_ms: 0]}, id: make_ref())

    for budget <- [1, 100] do
      server = start_store(memory_budget_bytes: budget)
      assert incr(:key, 1, 100, now, server: server, timeout: 5_000) == {:error, :too_large}
      assert get(:key, now, server: server, timeout: 5_000) == :not_found
    end
  end

  test "formatted status and crash formatting redact keys, values, messages and logs", %{
    now: now,
    server: server,
    opts: opts,
  } do
    assert cas("PRIVATE-KEY", :missing, "PRIVATE-VALUE", 100, now, opts) == :ok
    status = inspect(:sys.get_status(server), limit: :infinity, printable_limit: :infinity)
    refute status =~ "PRIVATE"

    formatted =
      format_status(%{
        state: %{secret: "PRIVATE"},
        message: {:cas, "PRIVATE"},
        log: [{:in, "PRIVATE"}],
        reason: {:badarg, "PRIVATE"},
      })

    refute inspect(formatted) =~ "PRIVATE"
  end

  test "an actual callback crash scrubs payloads and the supervised store restarts empty", %{
    now: now,
  } do
    server = start_store(name: :counter_store_crash_test)
    opts = [server: :counter_store_crash_test, timeout: 5_000]
    assert cas("PRIVATE-KEY", :missing, "PRIVATE-VALUE", 100, now, opts) == :ok
    monitor = Process.monitor(server)

    log =
      capture_log(fn ->
        # Not a table: the sweep's ETS call raises with this marker in its arguments.
        :sys.replace_state(server, &%{&1 | entries: "PRIVATE-TABLE"})
        send(server, :sweep)
        assert_receive {:DOWN, ^monitor, :process, ^server, reason}
        refute inspect(reason) =~ "PRIVATE"
        {%RuntimeError{}, stack} = reason
        assert Enum.any?(stack, &match?({:ets, :select_delete, 2, _}, &1))

        assert_eventually(fn ->
          replacement = Process.whereis(:counter_store_crash_test)
          assert is_pid(replacement) and replacement != server
          assert get("PRIVATE-KEY", now, opts) == :not_found
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

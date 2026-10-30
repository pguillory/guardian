defmodule Guardian.Counters.StoreTest do
  use ExUnit.Case, async: true
  import Guardian.Counters.Store

  alias Guardian.Counters.Store

  # Operations take `now` as data, anchored on the live monotonic clock so the real
  # housekeeping sweep agrees with the test about what has expired. Stores never sweep
  # on their own unless a test asks for an interval.
  setup do
    server = start_store([])
    now = System.monotonic_time(:millisecond)
    %{server: server, now: now, base: now, opts: [server: server, timeout: 5_000]}
  end

  defp contend(count, write) do
    1..count
    |> Task.async_stream(write, max_concurrency: count)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp start_store(opts) do
    start_supervised!(
      {Store, Keyword.merge([name: nil, sweep_interval_ms: 3_600_000], opts)},
      id: make_ref()
    )
  end

  test "misses, stored nil and small integer tokens", %{now: now, opts: opts} do
    assert {:ok, %{keys: 0, memory_bytes: 0}} = stats(opts)
    assert get(:missing, now, opts) == :not_found
    assert gets(:missing, now, opts) == :not_found
    assert add(nil, nil, 100, now, opts) == :ok
    assert get(nil, now, opts) == {:ok, nil}
    assert {:ok, nil, token} = gets(nil, now, opts)
    # A small integer: no heap words beyond the term itself.
    assert is_integer(token) and :erts_debug.flat_size(token) == 0
  end

  test "add creates only absent keys and cas only replaces matching rows", %{
    now: now,
    opts: opts,
  } do
    assert cas(:a, 1, 1, 100, now, opts) == :not_found
    assert get(:a, now, opts) == :not_found
    assert add(:a, 1, 100, now, opts) == :ok
    assert add(:a, 2, 100, now, opts) == {:error, :not_stored}
    assert {:ok, 1, token} = gets(:a, now, opts)
    assert add(:b, 1, 100, now, opts) == :ok
    assert cas(:b, token, 2, 100, now, opts) == {:error, :exists}
    assert cas(:a, token, 2, 100, now, opts) == :ok
    assert {:ok, 2, replacement} = gets(:a, now, opts)
    refute replacement == token
    assert cas(:a, token, 3, 100, now, opts) == {:error, :exists}
    assert incr(:a, 1, 100, now, opts) == {:ok, 3}
    assert cas(:a, replacement, 4, 100, now, opts) == {:error, :exists}
    assert {:ok, 3, before_zero} = gets(:a, now, opts)
    assert incr(:a, 0, 100, now, opts) == {:ok, 3}
    assert cas(:a, before_zero, 4, 100, now, opts) == {:error, :exists}
  end

  test "a token that is not an integer is an invalid request", %{now: now, opts: opts} do
    assert add(:a, 1, 100, now, opts) == :ok

    for token <- [:missing, make_ref(), {make_ref(), 1}, nil, 1.0] do
      assert cas(:a, token, 2, 100, now, opts) == {:error, :invalid_request}
    end

    assert get(:a, now, opts) == {:ok, 1}
  end

  test "add takes over an expired row and cas does not", %{now: now, base: base, opts: opts} do
    assert add(:a, "old", 10, now, opts) == :ok
    assert {:ok, "old", token} = gets(:a, now, opts)
    now = base + 10
    assert cas(:a, token, "new", 100, now, opts) == :not_found
    assert get(:a, now, opts) == :not_found
    assert add(:a, "fresh", 100, now, opts) == :ok
    assert get(:a, now, opts) == {:ok, "fresh"}
  end

  test "a cas sets a new expiry and an incr keeps it", %{now: now, base: base, opts: opts} do
    assert add(:a, 1, 10, now, opts) == :ok
    assert {:ok, 1, token} = gets(:a, now, opts)
    assert cas(:a, token, 2, 100, now, opts) == :ok
    now = base + 50
    assert incr(:a, 1, 1_000, now, opts) == {:ok, 3}
    now = base + 99
    assert get(:a, now, opts) == {:ok, 3}
    assert get(:a, base + 100, opts) == :not_found
  end

  test "a token from another store does not match", %{now: now, opts: opts} do
    assert add(:key, 1, 100, now, opts) == :ok
    assert {:ok, 1, token} = gets(:key, now, opts)
    other = [server: start_store([]), timeout: 5_000]
    assert cas(:key, token, 2, 100, now, other) == :not_found
    assert add(:key, 1, 100, now, other) == :ok
    assert cas(:key, token, 2, 100, now, other) == {:error, :exists}
  end

  test "competing missing-key creates have exactly one winner", %{now: now, opts: opts} do
    results = contend(40, fn n -> add(:race, n, 100, now, opts) end)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_stored})) == 39
  end

  test "live cas contenders and contenders adding over an expired row each have one winner", %{
    now: now,
    base: base,
    opts: opts,
  } do
    add(:race, nil, 10, now, opts)
    assert {:ok, nil, token} = gets(:race, now, opts)

    results = contend(40, fn n -> cas(:race, token, n, 100, now, opts) end)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :exists})) == 39

    now = base + 100
    results = contend(40, fn n -> add(:race, n, 100, now, opts) end)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_stored})) == 39
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
    assert add(:text, "1", 100, now, opts) == :ok
    assert incr(:text, 1, 100, now, opts) == {:error, :not_integer}
    assert get(:text, now, opts) == {:ok, "1"}
  end

  test "incr expiry, expired integer/noninteger reuse, and stale tokens", %{
    now: now,
    base: base,
    opts: opts,
  } do
    assert incr(:count, 1, 100, now, opts) == {:ok, 1}
    assert {:ok, 1, token} = gets(:count, now, opts)
    now = base + 50
    assert incr(:count, 1, 1000, now, opts) == {:ok, 2}
    assert {:ok, 2, current} = gets(:count, now, opts)
    now = base + 100
    assert get(:count, now, opts) == :not_found
    assert cas(:count, token, 9, 100, now, opts) == :not_found
    assert incr(:count, 1, 100, now, opts) == {:ok, 1}
    assert cas(:count, current, 9, 100, now, opts) == {:error, :exists}
    assert add(:text, "old", 10, now, opts) == :ok
    now = base + 110
    assert incr(:text, 1, 100, now, opts) == {:ok, 1}
    assert add(:other, nil, 10, now, opts) == :ok
    now = base + 120
    assert add(:other, "new", 100, now, opts) == :ok
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
    assert add(:live, :binary.copy("x", 60_000), 600_000, now, opts) == :ok
    assert {:ok, _, token} = gets(:live, now, opts)
    assert add(:short, :binary.copy("y", 60_000), 10, now - 60_000, opts) == :ok
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
    add(:later, :binary.copy("x", 40_000), 1_000_000, now, opts)
    add(:earlier, :binary.copy("x", 40_000), 100_000, now, opts)
    assert {:ok, _, token} = gets(:earlier, now, opts)
    add(:middle, :binary.copy("x", 40_000), 500_000, now, opts)
    send(server, :sweep)
    :sys.get_state(server)
    assert get(:earlier, now, opts) == :not_found
    assert {:ok, _} = get(:later, now, opts)
    assert cas(:earlier, token, 7, 100, now, opts) == :not_found
    assert {:ok, %{memory_bytes: bytes}} = stats(opts)
    assert bytes < 100_000
    incr(:earlier, 1, 100, now, opts)
    assert cas(:earlier, token, 7, 100, now, opts) == {:error, :exists}
    for key <- 1..5, do: add(key, :binary.copy("x", 40_000), 1_000_000, now, opts)
    send(server, :sweep)
    :sys.get_state(server)
    assert {:ok, %{keys: 0}} = stats(opts)
  end

  test "large values are charged and oversize replacement preserves the old value", %{now: now} do
    server = start_store(memory_budget_bytes: 100_000)
    opts = [server: server, timeout: 5000]
    add(:a, "old", 100, now, opts)
    assert {:ok, "old", token} = gets(:a, now, opts)
    assert cas(:a, token, :binary.copy("x", 100_000), 100, now, opts) == {:error, :too_large}
    assert gets(:a, now, opts) == {:ok, "old", token}
    assert add(:b, :binary.copy("x", 60_000), 100, now, opts) == :ok
    assert {:ok, %{memory_bytes: bytes}} = stats(opts)
    assert bytes >= 60_000
  end

  test "opaque keys and replacement values cannot act as match patterns", %{now: now, opts: opts} do
    keys = [:"$1", :_, {:const, :"$2"}, %{a: :"$1"}, %{a: :"$1", b: 2}, 1, 1.0, 0.0, -0.0]

    for {key, n} <- Enum.with_index(keys) do
      assert add(key, n, 100, now, opts) == :ok
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

  test "a captured table reference cannot address a same-name replacement", %{now: now} do
    owner = start_store(name: :counter_generation_test)
    assert incr(:key, 1, 100, now, server: :counter_generation_test) == {:ok, 1}
    %{entries: old_table} = :sys.get_state(owner)
    GenServer.stop(owner)

    # The restarted store registers its name before init publishes it as ready, and a
    # call in between correctly answers :unavailable, so wait for the replacement's
    # answer, not its name.
    assert_eventually(fn ->
      assert get(:key, now, server: :counter_generation_test) == :not_found
    end)

    replacement = Process.whereis(:counter_generation_test)
    assert is_pid(replacement) and replacement != owner
    assert incr(:key, 1, 100, now, server: old_table) == {:error, :unavailable}
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
      assert add(:key, value, 100, now, opts) == {:error, :too_large}
    end

    for key <- [{:group, slice}, %{slice => [0]}, [nil, bits]] do
      assert add(key, 1, 100, now, opts) == :ok
      assert {:ok, 1} = get(key, now, opts)
    end

    assert {:ok, %{memory_bytes: encoded_bytes}} = stats(opts)
    assert encoded_bytes < 100_000
    %{entries: entries} = :sys.get_state(server)

    for {encoded_key, _, _, _} <- :ets.tab2list(entries),
        do: assert(:binary.referenced_byte_size(encoded_key) < 1_000)

    # A detached copy is small and can be stored; no blanket slice-size rejection.
    assert add(:key, :binary.copy(slice), 100, now, opts) == :ok

    roomy = start_store(memory_budget_bytes: 600_000)
    roomy_opts = [server: roomy, timeout: 5_000]
    assert add(:slice, slice, 100, now, roomy_opts) == :ok
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
      assert add(:key, 2, ttl, now, opts) == {:error, :invalid_request}
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
    assert add("PRIVATE-KEY", "PRIVATE-VALUE", 100, now, opts) == :ok
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

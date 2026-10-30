defmodule Guardian.Counters.Store do
  @moduledoc """
  Ephemeral counters in one public ETS set. Callers operate on atomic rows; the
  owner only sweeps expiry and reclaims memory. Stored nil differs from missing.
  The API follows memcached: get, gets, add, cas and incr, with its answers. Incr
  retains the expiry established at insertion; cas sets a new one, as memcached's
  does. A CAS token is one random integer stamped on the row by each write, so any
  mutation, including incr, replaces it atomically.

  The default 64 MiB budget charges ETS bytes plus encoded keys, values and retained
  binary backing. Housekeeping enforces it asynchronously; concurrent writes can
  temporarily exceed it. Individual oversized payloads are refused up front.

  Operations take `now`, the caller's current local monotonic milliseconds
  (`System.monotonic_time(:millisecond)` on this node), which judges and sets
  expiry for every operation of the request. Options are :server (registered name,
  PID or table reference), :timeout (50 ms by default) and a local
  monotonic-millisecond :deadline. Pipelines check the deadline, on the real clock,
  before every operation. Transport bounds caller waits separately. Housekeeping
  reads the real clock itself.

  ## Terms

    * **CAS** (compare-and-swap) is a write that succeeds only if the key is still
      as it was when read. Read with `gets/3`, compute the new value, then write it
      with `cas/6`. If another writer got in between, `cas/6` answers
      `{:error, :exists}` and nothing is stored. To create a key, use `add/5`.
    * A **token** is what `gets/3` returns beside the value: a stamp of the stored
      row at that moment, which `cas/6` hands back. It is one random 59-bit integer,
      and callers treat it as opaque. Every write gives the key a new one, so an old
      token, or one from another store or from before a restart, matches only by a
      1 in 2^59 chance per attempt. Such a match would overwrite whatever updates
      came since the read, in an advisory counter.
    * An **anchor** is not a Store concept: Store takes only a relative `ttl`.
      Absolute (anchored) expiries are converted before they reach it; see
      `Guardian.Counters.Transport` and `Guardian.Counters.Arrival`.
    * A **ttl** is a positive number of milliseconds, counted from `now`, that a
      row lives after `add/5`, `cas/6` or an `incr/5` that creates it. Expired rows read as missing and are deleted by the
      housekeeping sweep.

  Besides the per-operation results documented on each function, failures are fixed
  atoms that never carry keys or values: `{:error,
  :invalid_request}` for a bad `now`, options, operation or token;
  `{:error, :timeout}` when the deadline passes; `{:error, :too_large}` when the
  payload would exceed the memory budget; and `{:error, :unavailable}` when the
  store is missing or not ready, or its table goes away during a request. Counters are
  advisory, so callers treat these as "no answer" and carry on. Anything else raises.
  """
  use GenServer
  @default_budget 64 * 1024 * 1024
  @default_timeout 50
  @descriptor :counter_store_descriptor
  @sample_size 256
  @max_batch_operations 4_000
  @sweep_interval_ms 1_000
  @eviction_passes 4
  @minimum_row_words 16

  @doc """
  Starts the store and its one public ETS table.

  Options: `:name` (default `Guardian.Counters.Store`; the table takes the same name,
  and `nil` starts an unnamed store, found by PID or table reference),
  `:memory_budget_bytes` (positive integer; default from the
  `:counter_memory_budget_bytes` application setting, else 64 MiB) and
  `:sweep_interval_ms` (positive integer, default 1,000). Invalid values stop the
  process with `:invalid_options`, which refuses startup.
  """
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Reads the value stored under `key`.

  `key` is any term. Returns `{:ok, value}`, or `:not_found` when the key is
  missing or has expired (its expiry is at or before `now`). A stored `nil` comes
  back as `{:ok, nil}`, so it can be told apart from a missing key. Use `gets/3`
  instead when the value will be written back with `cas/6`.
  """
  def get(key, now, opts) do
    request({:get, key}, now, opts)
  end

  @doc """
  Reads the value under `key` together with a CAS token, for a later `cas/6`.

  Returns `{:ok, value, token}`, or `:not_found` when the key is missing or has
  expired (a caller that wants to create it then uses `add/5`). The token stands
  for the stored row that was read; hand it back to `cas/6` unchanged and do nothing
  else with it. Any write to the key, including an `incr/5` with delta 0, replaces
  it (see Terms for the chance of a match).
  """
  def gets(key, now, opts) do
    request({:gets, key}, now, opts)
  end

  @doc """
  Runs a list of operations in order and returns `{:ok, responses}`, one response
  per operation, each as the matching single call would give.

  Operations are `{:get, key}`, `{:gets, key}`, `{:add, key, value, ttl}`,
  `{:incr, key, delta, ttl}` and `{:cas, key, token, value, ttl}`, with the
  arguments of `get/3`, `gets/3`, `add/5`, `incr/5` and `cas/6`. All of them are judged against the one `now`. There is no
  snapshot or rollback: other callers can write between operations, and an
  operation that fails neither undoes nor blocks the others, except that the
  one deadline is checked before each operation: once it passes, that operation and
  every later one answers `{:error, :timeout}`. A nested `:stats` is also accepted.
  More than 4,000 operations, or something that is not a list, is
  `{:error, :invalid_request}` for the whole call.
  """
  def batch(operations, now, opts) do
    request({:batch, operations}, now, opts)
  end

  @doc """
  Creates `key` holding `value`, only if it is absent, like memcached's add.

  Returns `:ok` after storing, or `{:error, :not_stored}` when a live row exists. A
  lost race is a normal answer, not a failure: re-read with `gets/3` and try again.
  An expired row is replaced. The new row expires `ttl` milliseconds after `now`; a
  `ttl` that is not a positive integer is `{:error, :invalid_request}`.
  """
  def add(key, value, ttl, now, opts) do
    request({:add, key, value, ttl}, now, opts)
  end

  @doc """
  Compare-and-swap, like memcached's cas: replaces the value of an existing row only
  if `token` from `gets/3` still matches it. It never creates a key.

  Returns `:ok` after storing, `{:error, :exists}` when a live row holds a different
  token, or `:not_found` when there is no live row, even if an expired row still
  carries that token. Nothing is stored in the last two cases, and both are normal
  answers: re-read with `gets/3` and try again. Which of the two comes back is read
  just after the failed swap, so a concurrent write or expiry can tip it either way.
  A non-integer `token` is `{:error, :invalid_request}`, as is a `ttl` that is not a
  positive integer.

  The row then expires `ttl` milliseconds after `now`, replacing its old expiry, so
  repeated calls with fresh ttls keep it alive.
  """
  def cas(key, token, value, ttl, now, opts) do
    request({:cas, key, token, value, ttl}, now, opts)
  end

  @doc """
  Atomically adds the integer `delta` to the integer under `key`, creating the key
  at `delta` if it is missing, and returns `{:ok, new_value}`.

  A new row expires `ttl` milliseconds after `now` (`ttl` must be a positive
  integer); an existing row keeps its original expiry. Every successful call,
  including one with delta 0, gives the row a new token, so earlier `gets/3` tokens
  stop matching (see Terms for the chance of a match). Other results:
  `{:error, :not_integer}` when the key holds a non-integer value, and `{:error, :expired}` when the key has expired. A row found
  expired (or lost in a race with a concurrent change) is deleted and recreated
  once; `:expired` is returned when the retry fails the same way, so callers
  can treat it as a definite failure. Unlike `cas/6`, there is no read first:
  the add itself is one atomic step.
  """
  def incr(key, delta, ttl, now, opts) do
    request({:incr, key, delta, ttl}, now, opts)
  end

  @doc """
  Approximate aggregate diagnostics under concurrent writes; scans resident rows.

  Returns `{:ok, %{keys: count, memory_bytes: bytes, memory_budget_bytes: budget}}`.
  Expiry is not judged, so rows that have expired but were not yet swept are
  counted. Takes only `opts`; it needs no `now`.
  """
  def stats(opts \\ []) do
    # Stats judge no expiry, so they take no `now`; the request's is never read.
    request(:stats, System.monotonic_time(:millisecond), opts)
  end

  # Malformed options are checked, not rescued.
  defp request(operation, now, opts) do
    with :ok <- valid_now(now),
         {:ok, deadline} <- request_deadline(opts),
         :ok <- before_deadline(deadline),
         {:ok, state} <- descriptor(Keyword.get(opts, :server, __MODULE__)),
         :ok <- before_deadline(deadline) do
      execute_request(operation, state, now, deadline)
    end
  end

  defp valid_now(now) do
    if is_integer(now), do: :ok, else: {:error, :invalid_request}
  end

  # Validates the options, in order: a keyword list, a positive integer :timeout, then
  # an integer :deadline. The request's deadline is the earlier of that and now plus
  # the timeout.
  defp request_deadline(opts) do
    with true <- Keyword.keyword?(opts),
         timeout when is_integer(timeout) and timeout > 0 <-
           Keyword.get(opts, :timeout, @default_timeout),
         now = System.monotonic_time(:millisecond),
         deadline when is_integer(deadline) <- Keyword.get(opts, :deadline, now + timeout) do
      {:ok, min(deadline, now + timeout)}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp descriptor(server) do
    table =
      cond do
        is_atom(server) ->
          :ets.whereis(server)

        is_reference(server) ->
          server

        is_pid(server) ->
          case :erlang.process_info(server, {:dictionary, @descriptor}) do
            {{:dictionary, @descriptor}, tid} -> tid
            _ -> :undefined
          end

        true ->
          :undefined
      end

    case :ets.lookup(table, @descriptor) do
      [{@descriptor, %{ready: true} = state}] -> {:ok, state}
      _ -> {:error, :unavailable}
    end
  rescue
    # No such table: the store is down or restarting, and counters fail open.
    ArgumentError -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    budget =
      Keyword.get(
        opts,
        :memory_budget_bytes,
        Application.get_env(:guardian, :counter_memory_budget_bytes, @default_budget)
      )

    interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)

    if is_integer(budget) and budget > 0 and is_integer(interval) and interval > 0 do
      name = Keyword.get(opts, :name, __MODULE__)

      options = [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: :auto,
        decentralized_counters: true,
      ]

      table = :ets.new(name || __MODULE__, if(name, do: [:named_table | options], else: options))
      entries = if name, do: :ets.whereis(name), else: table
      Process.put(@descriptor, entries)

      descriptor = %{
        entries: entries,
        budget: budget,
        baseline_bytes: 0,
        ready: false,
      }

      # Include the descriptor in fixed overhead before publishing it to callers.
      :ets.insert(entries, {@descriptor, descriptor})
      descriptor = %{descriptor | baseline_bytes: table_bytes(entries), ready: true}
      :ets.insert(entries, {@descriptor, descriptor})
      state = Map.merge(descriptor, %{sweep_interval_ms: interval, sweep_tag: make_ref()})
      Process.send_after(self(), {:sweep, state.sweep_tag}, interval)
      {:ok, state}
    else
      {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_call(_, _, state) do
    {:reply, {:error, :invalid_request}, state}
  end

  @impl true
  def handle_info({:sweep, tag}, %{sweep_tag: tag} = state) do
    over_budget = sweep(state)
    state = %{state | sweep_tag: make_ref()}

    Process.send_after(
      self(),
      {:sweep, state.sweep_tag},
      if(over_budget, do: 0, else: state.sweep_interval_ms)
    )

    {:noreply, state}
  end

  # Manual sweeps never create a second periodic timer chain.
  def handle_info(:sweep, state) do
    sweep(state)
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp execute_request({:batch, operations}, state, now, deadline)
       when is_list(operations) and length(operations) <= @max_batch_operations do
    {:ok, Enum.map(operations, &execute_one(&1, state, now, deadline))}
  end

  defp execute_request(operation, state, now, deadline) do
    execute_one(operation, state, now, deadline)
  end

  defp execute_one(operation, state, now, deadline) do
    with :ok <- before_deadline(deadline), do: execute(operation, state, now, deadline)
  rescue
    # The store restarted under this request and took its table along, which reads as
    # unavailable, like a store that is down. Any other ArgumentError is a bug.
    error in ArgumentError ->
      if :ets.info(state.entries, :id) == :undefined,
        do: {:error, :unavailable},
        else: reraise(error, __STACKTRACE__)
  end

  defp execute({kind, key}, state, now, deadline) when kind in [:get, :gets] do
    key = encode(key)

    with :ok <- before_deadline(deadline) do
      case :ets.lookup(state.entries, key) do
        [{_, value, expiry, version}] when expiry > now ->
          if kind == :get, do: {:ok, value}, else: {:ok, value, version}

        _ ->
          :not_found
      end
    end
  end

  defp execute({:incr, key, delta, ttl}, state, now, deadline)
       when is_integer(delta) and is_integer(ttl) and ttl > 0 do
    key = encode(key)

    with :ok <- fits(state, key, delta), :ok <- before_deadline(deadline) do
      increment(state, key, delta, now + ttl, now, deadline, true)
    end
  end

  defp execute({:add, key, value, ttl}, state, now, deadline)
       when is_integer(ttl) and ttl > 0 do
    key = encode(key)

    with :ok <- fits(state, key, value), :ok <- before_deadline(deadline) do
      add_row(state.entries, key, value, now + ttl, now, deadline)
    end
  end

  defp execute({:cas, key, token, value, ttl}, state, now, deadline)
       when is_integer(token) and is_integer(ttl) and ttl > 0 do
    key = encode(key)

    with :ok <- fits(state, key, value), :ok <- before_deadline(deadline) do
      swap_row(state.entries, key, token, value, now + ttl, now)
    end
  end

  defp execute(:stats, state, _now, _deadline) do
    {bytes, _sample, count} = measure(state)
    {:ok, %{keys: count, memory_bytes: bytes, memory_budget_bytes: state.budget}}
  end

  defp execute(_, _, _, _) do
    {:error, :invalid_request}
  end

  # Fully bound binary keys make select_replace/delete keyed operations, including
  # when the original opaque key contains maps or match-spec atoms.
  defp encode(key) do
    :erlang.term_to_binary(key, [:deterministic])
  end

  # 59 bits stay small integers, and crypto rather than :rand because Transport's
  # workers are fresh processes: a first :rand draw has far fewer effective bits.
  defp version do
    <<random::59, _::5>> = :crypto.strong_rand_bytes(8)
    random
  end

  defp add_row(table, key, value, expiry, now, deadline) do
    if :ets.insert_new(table, {key, value, expiry, version()}) do
      :ok
    else
      with :ok <- before_deadline(deadline) do
        if delete_expired(table, key, now) == 1 do
          with :ok <- before_deadline(deadline) do
            if :ets.insert_new(table, {key, value, expiry, version()}),
              do: :ok,
              else: {:error, :not_stored}
          end
        else
          {:error, :not_stored}
        end
      end
    end
  end

  defp swap_row(table, key, token, value, expiry, now) do
    count =
      :ets.select_replace(table, [
        {{key, :_, :"$1", token}, [{:>, :"$1", now}],
         [{{key, {:const, value}, expiry, version()}}]},
      ])

    cond do
      count == 1 -> :ok
      # Reads only the expiry, so a large value is not copied to tell these apart.
      :ets.lookup_element(table, key, 3, now) > now -> {:error, :exists}
      true -> :not_found
    end
  end

  defp increment(state, key, delta, expiry, now, deadline, retry?) do
    next_version = version()

    result =
      try do
        [value, _, expires] =
          :ets.update_counter(
            state.entries,
            key,
            [{2, delta}, {4, 0, -1, next_version}, {3, 0}],
            {key, 0, expiry, next_version}
          )

        if expires > now, do: {:ok, value}, else: :expired
      rescue
        # update_counter's only answer for a row it can't add to: find out why.
        ArgumentError ->
          case :ets.lookup(state.entries, key) do
            [{_, _, expires, _}] when expires <= now -> :expired
            [{_, value, _, _}] when not is_integer(value) -> {:error, :not_integer}
            _ -> :retry
          end
      end

    case result do
      outcome when outcome in [:expired, :retry] and retry? ->
        with :ok <- before_deadline(deadline) do
          delete_expired(state.entries, key, now)

          with :ok <- before_deadline(deadline),
               do: increment(state, key, delta, expiry, now, deadline, false)
        end

      outcome when outcome in [:expired, :retry] ->
        {:error, :expired}

      reply ->
        reply
    end
  end

  defp delete_expired(table, key, now) do
    :ets.select_delete(table, [{{key, :_, :"$1", :_}, [{:"=<", :"$1", now}], [true]}])
  end

  defp fits(state, key, value) do
    if payload_bytes({key, value}) + @minimum_row_words * :erlang.system_info(:wordsize) >
         state.budget,
       do: {:error, :too_large},
       else: :ok
  end

  defp before_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :timeout}
  end

  # Housekeeping runs on a timer, so it reads the real clock.
  defp sweep(state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(state.entries, [{{:_, :_, :"$1", :_}, [{:"=<", :"$1", now}], [true]}])
    evict(state, @eviction_passes)
  end

  defp evict(state, passes) do
    {bytes, sample, _count} = measure(state)

    if bytes >= state.budget and sample != [] do
      if passes == 0 do
        true
      else
        sorted = Enum.sort(sample)
        cutoff = Enum.at(sorted, div(length(sorted), 2))

        :ets.select_delete(
          state.entries,
          [{{:_, :_, :"$1", :_}, [{:"=<", :"$1", cutoff}], [true]}]
        )

        evict(state, passes - 1)
      end
    else
      false
    end
  end

  defp measure(state) do
    {payload, sample, count} =
      :ets.foldl(
        fn
          {key, value, expiry, _}, {bytes, sample, count} ->
            sample = if count < @sample_size, do: [expiry | sample], else: sample
            {bytes + payload_bytes({key, value}), sample, count + 1}

          _, acc ->
            acc
        end,
        {0, [], 0},
        state.entries
      )

    {max(0, table_bytes(state.entries) - state.baseline_bytes) + payload, sample, count}
  end

  defp table_bytes(table) do
    :ets.info(table, :memory) * :erlang.system_info(:wordsize)
  end

  defp payload_bytes(term) do
    :erlang.external_size(term) + retained_binary_bytes(term)
  end

  defp retained_binary_bytes(term) when is_bitstring(term) do
    max(0, :binary.referenced_byte_size(term) - div(bit_size(term) + 7, 8))
  end

  defp retained_binary_bytes([head | tail]) do
    retained_binary_bytes(head) + retained_binary_bytes(tail)
  end

  defp retained_binary_bytes(term) when is_tuple(term) do
    term |> Tuple.to_list() |> retained_binary_bytes()
  end

  defp retained_binary_bytes(term) when is_map(term) do
    :maps.fold(
      fn key, value, total ->
        total + retained_binary_bytes(key) + retained_binary_bytes(value)
      end,
      0,
      term
    )
  end

  defp retained_binary_bytes(term) when is_function(term) do
    {:env, environment} = :erlang.fun_info(term, :env)
    retained_binary_bytes(environment)
  end

  defp retained_binary_bytes(_) do
    0
  end
end

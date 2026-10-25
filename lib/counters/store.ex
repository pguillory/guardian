defmodule Guardian.Counters.Store do
  @moduledoc """
  Ephemeral, node-local counter storage. One owner serializes operations on private
  ETS tables, so increments and compare-and-swap are atomic. Keys and values are
  opaque terms; `:not_found` is distinct from a stored nil.

  Mutations take a positive TTL in milliseconds, replacing any previous TTL. Reads
  do not refresh it. CAS accepts a token from gets, or `:missing` to create a key.
  Every mutation creates a fresh reference token, even after an owner restart.

  The default budget is 64 MiB (`:guardian, :counter_memory_budget_bytes`). It
  charges ETS memory above empty-table overhead plus serialized payload sizes and
  retained binary backing allocations. At capacity, expired keys are reclaimed
  before roughly the oldest half of live keys are discarded, repeating if needed.
  Updating a key does not make it
  younger. This bounds resident entries, not mailbox or temporary process memory.

  Options for operations: `:server` (default this module), `:timeout` (default
  50 ms), and an optional local monotonic-millisecond `:deadline`. A queued request
  whose deadline has elapsed cannot mutate later. A timeout after execution began
  has an uncertain outcome and must not be retried as an increment.
  """

  use GenServer

  @default_budget 64 * 1024 * 1024
  @default_timeout 50
  @max_read_keys 4
  @sweep_interval_ms 1_000
  @sweep_batch 256

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def get(key, opts \\ []), do: request({:get, key}, opts)

  @doc "Reads up to four keys in input order, in one store turn."
  def get_many(keys, opts \\ []), do: request({:get_many, keys}, opts)

  def gets(key, opts \\ []), do: request({:gets, key}, opts)

  @doc "Pipelines up to 4,000 operations, checking the queued deadline before each."
  def batch(operations, opts \\ []), do: request({:batch, operations}, opts)

  def cas(key, expected, value, ttl_ms, opts \\ []),
    do: request({:cas, key, expected, value, ttl_ms}, opts)

  def incr(key, delta, ttl_ms, opts \\ []),
    do: request({:incr, key, delta, ttl_ms}, opts)

  @doc "Resident key count and aggregate memory accounting; never keys or values."
  def stats(opts \\ []), do: request(:stats, opts)

  defp request(operation, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    now = System.monotonic_time(:millisecond)
    deadline = Keyword.get(opts, :deadline, now + timeout)

    cond do
      not is_integer(timeout) or timeout <= 0 or not is_integer(deadline) ->
        {:error, :invalid_request}

      deadline <= now ->
        {:error, :timeout}

      true ->
        deadline = min(deadline, now + timeout)

        GenServer.call(
          Keyword.get(opts, :server, __MODULE__),
          {:operation, deadline, operation},
          deadline - now
        )
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
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
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    if is_integer(budget) and budget > 0 and is_integer(interval) and interval > 0 and
         is_function(clock, 0) do
      state = %{
        entries: :ets.new(__MODULE__, [:set, :private]),
        oldest: :ets.new(__MODULE__, [:ordered_set, :private]),
        expiry: :ets.new(__MODULE__, [:ordered_set, :private]),
        budget: budget,
        payload_bytes: 0,
        sequence: 0,
        clock: clock,
        sweep_interval_ms: interval,
        baseline_bytes: 0,
        sweep_tag: make_ref(),
      }

      state = %{state | baseline_bytes: table_bytes(state)}
      Process.send_after(self(), {:sweep, state.sweep_tag}, interval)
      {:ok, state}
    else
      {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_call({:operation, deadline, operation}, _from, state) when is_integer(deadline) do
    scrubbed(fn ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:reply, {:error, :timeout}, state}
      else
        {reply, state} = execute_request(operation, state, deadline)
        {:reply, reply, state}
      end
    end)
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :invalid_request}, state}

  @impl true
  def handle_info({:sweep, tag}, %{sweep_tag: tag} = state) do
    scrubbed(fn ->
      now = state.clock.()
      state = sweep(state, now, @sweep_batch)
      delay = if expired?(state, now), do: 0, else: state.sweep_interval_ms
      state = %{state | sweep_tag: make_ref()}
      Process.send_after(self(), {:sweep, state.sweep_tag}, delay)
      {:noreply, state}
    end)
  end

  # A manual sweep is one turn of work, never a second periodic timer chain.
  def handle_info(:sweep, state),
    do: scrubbed(fn -> {:noreply, sweep(state, state.clock.(), @sweep_batch)} end)

  def handle_info(_message, state), do: {:noreply, state}

  defp execute_request({:batch, operations}, state, deadline)
       when is_list(operations) and length(operations) <= 4_000 do
    {results, state} =
      Enum.map_reduce(operations, state, fn operation, state ->
        if System.monotonic_time(:millisecond) >= deadline do
          {{:error, :timeout}, state}
        else
          execute(operation, state, state.clock.())
        end
      end)

    {{:ok, results}, state}
  end

  defp execute_request(operation, state, _deadline),
    do: execute(operation, state, state.clock.())

  defp execute({operation, key}, state, now) when operation in [:get, :gets] do
    {entry, state} = fetch(state, key, now)
    {read_result(entry, operation), state}
  end

  defp execute({:get_many, keys}, state, now)
       when is_list(keys) and length(keys) <= @max_read_keys do
    {results, state} =
      Enum.map_reduce(keys, state, fn key, state ->
        {entry, state} = fetch(state, key, now)
        {read_result(entry, :get), state}
      end)

    {{:ok, results}, state}
  end

  defp execute({:cas, key, expected, value, ttl}, state, now)
       when (is_reference(expected) or expected == :missing) and is_integer(ttl) and ttl > 0 do
    {entry, state} = fetch(state, key, now)

    case {entry, expected} do
      {nil, :missing} -> write(state, key, value, ttl, nil, now, :ok)
      {{_, _, ^expected, _, _, _}, _} -> write(state, key, value, ttl, entry, now, :ok)
      _ -> {{:error, :conflict}, state}
    end
  end

  defp execute({:incr, key, delta, ttl}, state, now)
       when is_integer(delta) and is_integer(ttl) and ttl > 0 do
    {entry, state} = fetch(state, key, now)

    case entry do
      nil ->
        write(state, key, delta, ttl, nil, now, {:ok, delta})

      {_, value, _, _, _, _} when is_integer(value) ->
        write(state, key, value + delta, ttl, entry, now, {:ok, value + delta})

      _ ->
        {{:error, :not_integer}, state}
    end
  end

  defp execute(:stats, state, _now) do
    {{:ok,
      %{
        keys: :ets.info(state.entries, :size),
        memory_bytes: memory_bytes(state),
        memory_budget_bytes: state.budget,
      }}, state}
  end

  defp execute(_operation, state, _now), do: {{:error, :invalid_request}, state}

  defp read_result(nil, _operation), do: :not_found
  defp read_result({_, value, _, _, _, _}, :get), do: {:ok, value}
  defp read_result({_, value, token, _, _, _}, :gets), do: {:ok, value, token}

  defp fetch(state, key, now) do
    case :ets.lookup(state.entries, key) do
      [] -> {nil, state}
      [{_, _, _, expires, _, _} = entry] when expires <= now -> {nil, remove(state, entry)}
      [entry] -> {entry, state}
    end
  end

  defp write(state, key, value, ttl, previous, now, reply) do
    # ETS memory excludes off-heap binary contents. A sub-binary also retains its
    # whole backing allocation, even when its serialized visible bytes are tiny.
    # Keys are retained in all three tables: entries, oldest and expiry.
    charge = payload_bytes({key, value}) + 2 * payload_bytes(key)

    if charge > state.budget do
      {{:error, :too_large}, state}
    else
      {sequence, state} =
        case previous do
          nil -> {state.sequence + 1, %{state | sequence: state.sequence + 1}}
          {_, _, _, _, sequence, _} -> {sequence, remove(state, previous)}
        end

      expires = now + ttl
      :ets.insert(state.entries, {key, value, make_ref(), expires, sequence, charge})
      :ets.insert(state.oldest, {sequence, key})
      :ets.insert(state.expiry, {{expires, sequence}, key})
      state = %{state | payload_bytes: state.payload_bytes + charge}
      # Reclaim the entire expired backlog before throwing away live counts.
      # Like bulk eviction, this exceptional capacity path can outlast a caller.
      state = if memory_bytes(state) >= state.budget, do: sweep(state, now, :all), else: state
      {state, oversized} = evict(state, key)

      case :ets.lookup(state.entries, key) do
        [] when oversized -> {{:error, :too_large}, state}
        [] -> {{:error, :evicted}, state}
        [_] -> {reply, state}
      end
    end
  end

  # Entries are {key, value, CAS token, monotonic expiry, insertion sequence, charge}.
  defp remove(state, {key, _, _, expires, sequence, charge}) do
    :ets.delete(state.entries, key)
    :ets.delete(state.oldest, sequence)
    :ets.delete(state.expiry, {expires, sequence})
    %{state | payload_bytes: state.payload_bytes - charge}
  end

  defp evict(state, written_key) do
    size = :ets.info(state.entries, :size)

    if size > 0 and memory_bytes(state) >= state.budget do
      if size == 1 do
        sequence = :ets.first(state.oldest)
        [{^sequence, key}] = :ets.lookup(state.oldest, sequence)
        [entry] = :ets.lookup(state.entries, key)
        {remove(state, entry), key === written_key}
      else
        state |> evict_oldest(div(size + 1, 2)) |> evict(written_key)
      end
    else
      {state, false}
    end
  end

  defp evict_oldest(state, 0), do: state

  defp evict_oldest(state, count) do
    sequence = :ets.first(state.oldest)
    [{^sequence, key}] = :ets.lookup(state.oldest, sequence)
    [entry] = :ets.lookup(state.entries, key)
    state |> remove(entry) |> evict_oldest(count - 1)
  end

  defp sweep(state, _now, 0), do: state

  defp sweep(state, now, left) do
    case :ets.first(state.expiry) do
      {expires, _sequence} = expiry when expires <= now ->
        [{^expiry, key}] = :ets.lookup(state.expiry, expiry)
        [entry] = :ets.lookup(state.entries, key)
        next = if left == :all, do: :all, else: left - 1
        state |> remove(entry) |> sweep(now, next)

      _ ->
        state
    end
  end

  defp expired?(state, now) do
    case :ets.first(state.expiry) do
      {expires, _sequence} -> expires <= now
      _ -> false
    end
  end

  defp table_bytes(state) do
    Enum.sum(
      for table <- [state.entries, state.oldest, state.expiry], do: :ets.info(table, :memory)
    ) *
      :erlang.system_info(:wordsize)
  end

  defp payload_bytes(term), do: :erlang.external_size(term) + retained_binary_bytes(term)

  defp retained_binary_bytes(term) when is_bitstring(term),
    do: max(0, :binary.referenced_byte_size(term) - div(bit_size(term) + 7, 8))

  defp retained_binary_bytes([head | tail]),
    do: retained_binary_bytes(head) + retained_binary_bytes(tail)

  defp retained_binary_bytes(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> retained_binary_bytes()

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

  defp retained_binary_bytes(_term), do: 0

  defp memory_bytes(state),
    do: max(0, table_bytes(state) - state.baseline_bytes) + state.payload_bytes

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [])
    |> Map.put(:reason, :redacted)
  end

  # A callback failure resets the store rather than leaving partially changed ETS
  # with stale accounting. Never expose the operation's values through its stack.
  defp scrubbed(fun) do
    fun.()
  catch
    _kind, _reason ->
      stack = Enum.map(__STACKTRACE__, &redact_frame/1)

      :erlang.raise(
        :error,
        %RuntimeError{message: "Guardian.Counters.Store failed (details redacted)"},
        stack
      )
  end

  defp redact_frame({module, function, args, location}),
    do: {module, function, arity(args), Keyword.take(location, [:file, :line])}

  defp redact_frame({_fun, args, location}),
    do: {:erlang, :apply, arity(args), Keyword.take(location, [:file, :line])}

  defp redact_frame(_frame), do: {:erlang, :apply, 0, []}

  defp arity(args) when is_list(args), do: length(args)
  defp arity(args), do: args
end

defmodule Guardian.Counters.Store do
  @moduledoc """
  Ephemeral counters in one public ETS set. Callers operate on atomic rows; the
  owner only sweeps expiry and reclaims memory. Stored nil differs from missing.
  Mutations retain the expiry established at insertion. CAS tokens identify the
  table generation and a unique mutation version, changed atomically by incr.

  The default 64 MiB budget charges ETS bytes plus encoded keys, values and retained
  binary backing. Housekeeping enforces it asynchronously; concurrent writes can
  temporarily exceed it. Individual oversized payloads are refused up front.

  Operations accept :server (registered name, PID or table reference), :timeout
  (50 ms by default) and a local monotonic-millisecond :deadline. Pipelines check
  the deadline before every operation. Transport bounds caller waits separately.
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

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def get(key, opts \\ []) do
    request({:get, key}, opts)
  end

  def gets(key, opts \\ []) do
    request({:gets, key}, opts)
  end

  @doc "Executes up to 4,000 operations in order, checking deadlines before each."
  def batch(operations, opts \\ []) do
    request({:batch, operations}, opts)
  end

  def cas(key, expected, value, ttl, opts \\ []) do
    request({:cas, key, expected, value, ttl}, opts)
  end

  def incr(key, delta, ttl, opts \\ []) do
    request({:incr, key, delta, ttl}, opts)
  end

  @doc "Approximate aggregate diagnostics under concurrent writes; scans resident rows."
  def stats(opts \\ []) do
    request(:stats, opts)
  end

  # The public boundary for direct callers and the remote endpoint's store call:
  # malformed options are checked, never rescued, and any other failure is a fixed,
  # value-free :unavailable, since counters are advisory and fail open.
  defp request(operation, opts) do
    with {:ok, deadline} <- request_deadline(opts),
         :ok <- before_deadline(deadline),
         {:ok, state} <- descriptor(Keyword.get(opts, :server, __MODULE__)),
         :ok <- before_deadline(deadline) do
      execute_request(operation, state, deadline)
    end
  catch
    _, _ -> {:error, :unavailable}
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
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    if is_integer(budget) and budget > 0 and is_integer(interval) and interval > 0 and
         is_function(clock, 0) do
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
        clock: clock,
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
    scrubbed(fn ->
      over_budget = sweep(state)
      state = %{state | sweep_tag: make_ref()}

      Process.send_after(
        self(),
        {:sweep, state.sweep_tag},
        if(over_budget, do: 0, else: state.sweep_interval_ms)
      )

      {:noreply, state}
    end)
  end

  # Manual sweeps never create a second periodic timer chain.
  def handle_info(:sweep, state) do
    scrubbed(fn ->
      sweep(state)
      {:noreply, state}
    end)
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp execute_request({:batch, operations}, state, deadline)
       when is_list(operations) and length(operations) <= @max_batch_operations do
    {:ok, Enum.map(operations, &execute_one(&1, state, deadline))}
  end

  defp execute_request(operation, state, deadline) do
    execute_one(operation, state, deadline)
  end

  defp execute_one(operation, state, deadline) do
    with :ok <- before_deadline(deadline) do
      now = state.clock.()
      with :ok <- before_deadline(deadline), do: execute(operation, state, now, deadline)
    end
  catch
    # A failing operation (the store's injected clock, say) fails alone, as :unavailable.
    _, _ -> {:error, :unavailable}
  end

  defp execute({kind, key}, state, now, deadline) when kind in [:get, :gets] do
    key = encode(key)

    with :ok <- before_deadline(deadline) do
      case :ets.lookup(state.entries, key) do
        [{_, value, expiry, version}] when expiry > now ->
          if kind == :get, do: {:ok, value}, else: {:ok, value, {state.entries, version}}

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

  defp execute({:cas, key, expected, value, ttl}, state, now, deadline)
       when is_integer(ttl) and ttl > 0 do
    # Legacy reference tokens remain well-formed foreign tokens: they conflict.
    if expected == :missing or is_reference(expected) or
         (is_tuple(expected) and tuple_size(expected) == 2 and
            is_reference(elem(expected, 0)) and is_integer(elem(expected, 1))) do
      key = encode(key)

      with :ok <- fits(state, key, value), :ok <- before_deadline(deadline) do
        compare_swap(state, key, expected, value, now + ttl, now, deadline)
      end
    else
      {:error, :invalid_request}
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

  defp version do
    System.unique_integer([:positive, :monotonic])
  end

  defp compare_swap(state, key, :missing, value, expiry, now, deadline) do
    if :ets.insert_new(state.entries, {key, value, expiry, version()}) do
      :ok
    else
      with :ok <- before_deadline(deadline) do
        if delete_expired(state.entries, key, now) == 1 do
          with :ok <- before_deadline(deadline) do
            if :ets.insert_new(state.entries, {key, value, expiry, version()}),
              do: :ok,
              else: {:error, :conflict}
          end
        else
          {:error, :conflict}
        end
      end
    end
  end

  defp compare_swap(%{entries: table}, key, {table, expected}, value, _expiry, now, _deadline) do
    count =
      :ets.select_replace(table, [
        {{key, :"$1", :"$2", expected}, [{:>, :"$2", now}],
         [{{key, {:const, value}, :"$2", version()}}]},
      ])

    if count == 1, do: :ok, else: {:error, :conflict}
  end

  defp compare_swap(_, _, _, _, _, _, _) do
    {:error, :conflict}
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

  defp sweep(state) do
    now = state.clock.()
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

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [])
    |> Map.put(:reason, :redacted)
  end

  defp scrubbed(fun) do
    fun.()
  catch
    _, _ ->
      stack = Guardian.Failure.stacktrace(__STACKTRACE__)

      :erlang.raise(
        :error,
        %RuntimeError{message: "Guardian.Counters.Store failed (details redacted)"},
        stack
      )
  end
end

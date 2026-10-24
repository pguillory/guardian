defmodule Counters.Cluster do
  @moduledoc """
  Availability-first routing for ephemeral counters. Store keys are
  `{identity, group_tuple, bucket}`; all buckets of a group share one owner.

  Keep `new_batch/0` outside replaceable rule workers and create one `new_event/2`
  per event. The event captures membership without readiness RPCs and has a 100 ms
  wall-clock counter phase. Calls have at most 50 ms; only failed call time spends
  the shared 250 ms batch allowance. A killed caller conservatively spends its
  outstanding reservation. Never retry an uncertain mutation.

  Errors are fixed atoms, never remote exceptions or event values. Missing keys
  and CAS conflicts are healthy responses. The rule integration supplies aggregate
  defaults on errors; this module does not change rules or ingest behavior itself.
  """
  use GenServer

  @operation_us 50_000
  @minimum_us 10_000
  @cooldown_us 1_000_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def new_batch do
    batch = :atomics.new(1, [])
    :atomics.put(batch, 1, 250_000)
    batch
  end

  @doc "Test options may shorten deadlines or substitute members/store/cooldown table."
  def new_event(batch, opts \\ []) do
    %{
      batch: batch,
      deadline: now() + min(100_000, Keyword.get(opts, :event_timeout_ms, 100) * 1_000),
      members: Keyword.get_lazy(opts, :members, fn -> [node() | Node.list()] end),
      timeout_us: min(@operation_us, Keyword.get(opts, :timeout_ms, 50) * 1_000),
      store: Keyword.get(opts, :store, Counters.Store),
      cooldown_table: Keyword.get(opts, :cooldown_table, __MODULE__),
    }
  end

  def get(key, event), do: request({:get, key}, [key], event)
  def gets(key, event), do: request({:gets, key}, [key], event)
  def get_many(keys, event), do: request({:get_many, keys}, keys, event)

  def cas(key, token, value, ttl_ms, event),
    do: request({:cas, key, token, value, ttl_ms}, [key], event)

  def incr(key, delta, ttl_ms, event),
    do: request({:incr, key, delta, ttl_ms}, [key], event)

  @doc "Rendezvous owner of {identity, group}; membership order never matters."
  def owner(routing_key, members) when is_list(members) and members != [] do
    encoded = encode(routing_key)

    Enum.max_by(members, fn member ->
      member_name = Atom.to_string(member)
      {:crypto.hash(:sha256, [encoded, encode(member_name)]), member_name}
    end)
  end

  defp request(operation, keys, event) do
    with {:ok, routing_key} <- routing_key(keys) do
      owner = owner(routing_key, event.members)
      table = event.cooldown_table

      if available?(table, owner),
        do: call(operation, owner, event),
        else: {:error, :cooldown}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp routing_key([{identity, group, bucket} | rest])
       when is_tuple(identity) and tuple_size(identity) == 3 and is_tuple(group) and
              is_integer(bucket) and length(rest) < 4 do
    {table, name, hash} = identity

    if is_binary(table) and is_binary(name) and is_binary(hash) and
         Enum.all?(rest, fn
           {other_identity, other_group, n} ->
             other_identity === identity and other_group === group and is_integer(n)

           _ ->
             false
         end) do
      {:ok, {identity, group}}
    else
      {:error, :invalid_request}
    end
  end

  defp routing_key(_), do: {:error, :invalid_request}

  defp call(operation, owner, event) do
    started = now()
    allowance = min(event.timeout_us, event.deadline - started)

    case reserve(event.batch, allowance) do
      :exhausted ->
        {:error, :budget_exhausted}

      reserved ->
        result = bounded_call(owner, operation, event.store, started + reserved)
        elapsed = max(0, now() - started)
        charged = if failed?(result), do: min(reserved, elapsed), else: 0
        :atomics.add(event.batch, 1, reserved - charged)
        if suspect?(result, reserved), do: suspect(event.cooldown_table, owner)
        result
    end
  end

  defp reserve(_batch, allowance) when allowance < @minimum_us, do: :exhausted

  defp reserve(batch, allowance) do
    remaining = :atomics.get(batch, 1)
    take = min(remaining, allowance)

    cond do
      take < @minimum_us -> :exhausted
      :atomics.compare_exchange(batch, 1, remaining, remaining - take) == :ok -> take
      true -> reserve(batch, allowance)
    end
  end

  # The guard never sends over distribution. Its linked worker may be blocked in
  # distribution flow control, so either caller timeout or caller death kills both.
  defp bounded_call(owner, operation, store, deadline) do
    caller = self()
    reply = :erlang.alias()

    {guard, monitor} =
      spawn_monitor(fn -> guard(caller, reply, owner, operation, store, deadline) end)

    try do
      receive do
        {^reply, result} -> result
        {:DOWN, ^monitor, :process, ^guard, _} -> {:error, :unavailable}
      after
        remaining_ms(deadline) -> {:error, :timeout}
      end
    after
      :erlang.unalias(reply)
      cleanup_monitor = Process.monitor(guard)
      Process.exit(guard, :kill)

      receive do
        {:DOWN, ^cleanup_monitor, :process, ^guard, _} -> :ok
      end

      Process.demonitor(monitor, [:flush])
      flush(reply)
    end
  end

  defp guard(caller, reply, owner, operation, store, deadline) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    guard = self()

    worker =
      spawn_link(fn -> send(guard, {:result, invoke(owner, operation, store, deadline)}) end)

    {result, wait_for_exit?} =
      receive do
        {:result, result} -> {result, true}
        {:DOWN, ^caller_monitor, :process, ^caller, _} -> {{:error, :unavailable}, true}
        {:EXIT, ^worker, _} -> {{:error, :unavailable}, false}
      after
        remaining_ms(deadline) -> {{:error, :timeout}, true}
      end

    Process.exit(worker, :kill)

    if wait_for_exit? do
      receive do
        {:EXIT, ^worker, _} -> :ok
      end
    end

    send(reply, {reply, result})
  end

  defp invoke(owner, operation, store, deadline) do
    duration_ms = remaining_ms(deadline)

    cond do
      duration_ms <= 0 ->
        {:error, :timeout}

      owner == node() ->
        local_operation(operation, store, duration_ms, deadline)

      true ->
        :erpc.call(
          owner,
          __MODULE__,
          :remote_operation,
          [operation, store, duration_ms],
          duration_ms
        )
    end
  catch
    :error, {:erpc, :timeout} -> {:error, :timeout}
    _, _ -> {:error, :unavailable}
  end

  @doc false
  def remote_operation(operation, store, duration_ms)
      when is_integer(duration_ms) and duration_ms > 0 and duration_ms <= 50 do
    local_operation(operation, store, duration_ms, now() + duration_ms * 1_000)
  end

  def remote_operation(_, _, _), do: {:error, :invalid_request}

  defp local_operation(operation, store, timeout, deadline) do
    opts = [server: store, timeout: timeout, deadline: Integer.floor_div(deadline, 1_000)]

    case operation do
      {:get, key} -> Counters.Store.get(key, opts)
      {:gets, key} -> Counters.Store.gets(key, opts)
      {:get_many, keys} -> Counters.Store.get_many(keys, opts)
      {:cas, key, token, value, ttl} -> Counters.Store.cas(key, token, value, ttl, opts)
      {:incr, key, delta, ttl} -> Counters.Store.incr(key, delta, ttl, opts)
      _ -> {:error, :invalid_request}
    end
  catch
    _, _ -> {:error, :unavailable}
  end

  defp failed?({:error, :conflict}), do: false
  defp failed?({:error, _}), do: true
  defp failed?(_), do: false
  defp suspect?({:error, :timeout}, allowance), do: allowance >= 25_000
  defp suspect?({:error, :unavailable}, _), do: true
  defp suspect?(_, _), do: false

  defp available?(table, owner) do
    case :ets.lookup(table, owner) do
      [{^owner, until}] -> until <= now()
      [] -> true
    end
  catch
    :error, :badarg -> false
  end

  defp suspect(table, owner) do
    if owner in [node() | Node.list()], do: :ets.insert(table, {owner, now() + @cooldown_us})
  catch
    :error, :badarg -> :ok
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :name, __MODULE__)

    :ets.new(table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

    :net_kernel.monitor_nodes(true)
    Process.send_after(self(), :cleanup, 1_000)
    {:ok, table}
  end

  @impl true
  def handle_info(:cleanup, table) do
    cleanup(table)
    Process.send_after(self(), :cleanup, 1_000)
    {:noreply, table}
  end

  def handle_info({kind, _node}, table) when kind in [:nodeup, :nodedown] do
    cleanup(table)
    {:noreply, table}
  end

  def handle_info(_, table), do: {:noreply, table}

  defp cleanup(table) do
    members = [node() | Node.list()]

    for {member, until} <- :ets.tab2list(table),
        member not in members or until <= now(),
        do: :ets.delete_object(table, {member, until})
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :redacted)
      |> Map.put(:message, :redacted)
      |> Map.put(:log, [])
      |> Map.put(:reason, :redacted)

  # Explicit encoding is independent of ETF/OTP versions. Float bit patterns keep
  # integers, floats, and signed zero distinct. No input is converted to an atom.
  defp encode(nil), do: "n"
  defp encode(false), do: "f"
  defp encode(true), do: "t"
  defp encode(value) when is_integer(value), do: sized("i", Integer.to_string(value))
  defp encode(value) when is_float(value), do: <<"d", value::float-64>>
  defp encode(value) when is_binary(value), do: sized("b", value)
  defp encode(value) when is_tuple(value), do: sequence("u", Tuple.to_list(value))
  defp encode(value) when is_list(value), do: sequence("l", value)

  defp encode(value) when is_map(value) do
    pairs =
      Enum.sort(for {key, item} <- value, do: IO.iodata_to_binary([encode(key), encode(item)]))

    sequence("m", pairs)
  end

  defp sequence(tag, values),
    do: [tag, <<length(values)::unsigned-64>>, Enum.map(values, &encode/1)]

  defp sized(tag, value), do: [tag, <<byte_size(value)::unsigned-64>>, value]
  defp now, do: System.monotonic_time(:microsecond)
  defp remaining_ms(deadline), do: max(0, div(deadline - now(), 1_000))

  defp flush(reply) do
    receive do
      {^reply, _} -> flush(reply)
    after
      0 -> :ok
    end
  end
end

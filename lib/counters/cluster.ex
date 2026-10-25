defmodule Guardian.Counters.Cluster do
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
      store: Keyword.get(opts, :store, Guardian.Counters.Store),
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

  @doc "Runs indexed operations in concurrent owner pipelines within the shared budgets."
  def batch(operations, event) when is_map(operations) do
    {groups, errors} =
      Enum.reduce(operations, {%{}, %{}}, fn {id, operation}, {groups, errors} ->
        case operation_owner(operation, event.members) do
          {:ok, owner} ->
            {Map.update(groups, owner, [{id, operation}], &[{id, operation} | &1]), errors}

          error ->
            {groups, Map.put(errors, id, error)}
        end
      end)

    pending = groups |> Enum.sort() |> Enum.map(fn {owner, ops} -> {owner, Enum.reverse(ops)} end)
    pipelines(pending, %{}, errors, event)
  end

  defp operation_owner(operation, members) do
    with true <- is_tuple(operation) and tuple_size(operation) in [2, 4, 5],
         kind when kind in [:get, :gets, :incr, :cas] <- elem(operation, 0),
         {:ok, routing} <- routing_key([elem(operation, 1)]) do
      {:ok, owner(routing, members)}
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp pipelines(pending, running, results, event) do
    {pending, running, results} = dispatch(pending, running, results, event)

    try do
      if map_size(running) == 0 do
        Enum.reduce(pending, results, fn {_, ops}, results ->
          put_results(results, ops, {:error, :budget_exhausted})
        end)
      else
        {reply, result, completed} = await_pipeline(running)
        handle = Map.fetch!(running, reply)
        cleanup_call(handle)
        result = normalize_pipeline(result, length(handle.operations))

        accounting =
          case result do
            {:ok, responses} -> {:pipeline, responses}
            other -> other
          end

        settle(accounting, handle.owner, event, handle.started, handle.reserved, completed)

        results =
          case result do
            {:ok, responses} ->
              Enum.zip(handle.operations, responses)
              |> Enum.reduce(results, fn {{id, _}, response}, acc ->
                Map.put(acc, id, response)
              end)

            {:error, _} = error ->
              put_results(results, handle.operations, error)
          end

        pipelines(pending, Map.delete(running, reply), results, event)
      end
    catch
      kind, reason ->
        Enum.each(running, fn {_, handle} -> cleanup_call(handle) end)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp dispatch([], running, results, _event), do: {[], running, results}

  defp dispatch(pending, running, results, event) do
    try do
      dispatch_owner(pending, running, results, event)
    catch
      kind, reason ->
        Enum.each(running, fn {_, handle} -> cleanup_call(handle) end)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp dispatch_owner([{owner, operations} | rest] = pending, running, results, event) do
    if available?(event.cooldown_table, owner) do
      started = now()

      case reserve(event.batch, min(event.timeout_us, event.deadline - started)) do
        :exhausted ->
          {pending, running, results}

        reserved ->
          {operations, results} = prepare_operations(operations, results)

          if operations == [] do
            :atomics.add(event.batch, 1, reserved)
            dispatch(rest, running, results, event)
          else
            handle =
              start_call(
                owner,
                {:batch, Enum.map(operations, &elem(&1, 1))},
                event.store,
                started + reserved
              )

            handle =
              Map.merge(handle, %{
                owner: owner,
                operations: operations,
                started: started,
                reserved: reserved,
              })

            dispatch(rest, Map.put(running, handle.reply, handle), results, event)
          end
      end
    else
      dispatch(rest, running, put_results(results, operations, {:error, :cooldown}), event)
    end
  end

  # Pending owners may wait for a reservation refund. Translate anchored expiries
  # only when their pipeline is about to dispatch, never when it first queues.
  defp prepare_operations(operations, results) do
    {ready, results} =
      Enum.reduce(operations, {[], results}, fn {id, op}, {ready, results} ->
        case prepare_operation(op) do
          {:ok, op} -> {[{id, op} | ready], results}
          error -> {ready, Map.put(results, id, error)}
        end
      end)

    {Enum.reverse(ready), results}
  end

  defp prepare_operation({:incr, key, delta, {:expires, expiry}}),
    do: mutation(expiry, fn ttl -> {:incr, key, delta, ttl} end)

  defp prepare_operation({:cas, key, token, value, {:expires, expiry}}),
    do: mutation(expiry, fn ttl -> {:cas, key, token, value, ttl} end)

  defp prepare_operation(op), do: {:ok, op}

  defp mutation(expiry, build) do
    ttl = expiry - System.monotonic_time(:millisecond)
    if ttl > 0, do: {:ok, build.(ttl)}, else: {:error, :expired}
  end

  defp await_pipeline(running) do
    deadline = running |> Map.values() |> Enum.map(& &1.deadline) |> Enum.min()
    monitors = Map.new(running, fn {reply, handle} -> {handle.monitor, reply} end)

    receive do
      {reply, result, completed} when is_map_key(running, reply) ->
        {reply, result, completed}

      {:DOWN, monitor, :process, _, _} when is_map_key(monitors, monitor) ->
        {Map.fetch!(monitors, monitor), {:error, :unavailable}, now()}
    after
      remaining_ms(deadline) ->
        {reply, _} = Enum.min_by(running, fn {_, handle} -> handle.deadline end)
        {reply, {:error, :timeout}, now()}
    end
  end

  defp normalize_pipeline({:ok, responses}, count)
       when is_list(responses) and length(responses) == count,
       do: {:ok, Enum.map(responses, &normalize_response/1)}

  defp normalize_pipeline({:error, reason} = error, _count) when is_atom(reason), do: error
  defp normalize_pipeline(_, _count), do: {:error, :invalid_response}

  defp normalize_response(response) when response in [:ok, :not_found], do: response
  defp normalize_response({:ok, _} = response), do: response
  defp normalize_response({:ok, _, _} = response), do: response
  defp normalize_response({:error, reason} = response) when is_atom(reason), do: response
  defp normalize_response(_), do: {:error, :invalid_response}

  defp put_results(results, operations, error),
    do: Enum.reduce(operations, results, fn {id, _}, acc -> Map.put(acc, id, error) end)

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
        settle(result, owner, event, started, reserved, now())
        result
    end
  end

  defp settle(result, owner, event, started, reserved, completed) do
    charged = if failed?(result), do: min(reserved, max(0, completed - started)), else: 0
    :atomics.add(event.batch, 1, reserved - charged)
    if suspect?(result, reserved), do: suspect(event.cooldown_table, owner)
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
    handle = start_call(owner, operation, store, deadline)

    try do
      receive do
        {reply, result, _} when reply == handle.reply ->
          result

        {:DOWN, monitor, :process, guard, _}
        when monitor == handle.monitor and guard == handle.guard ->
          {:error, :unavailable}
      after
        remaining_ms(deadline) -> {:error, :timeout}
      end
    after
      cleanup_call(handle)
    end
  end

  defp start_call(owner, operation, store, deadline) do
    caller = self()
    reply = :erlang.alias()

    {guard, monitor} =
      spawn_monitor(fn -> guard(caller, reply, owner, operation, store, deadline) end)

    %{reply: reply, guard: guard, monitor: monitor, deadline: deadline}
  end

  defp cleanup_call(%{reply: reply, guard: guard, monitor: monitor}) do
    :erlang.unalias(reply)
    cleanup_monitor = Process.monitor(guard)
    Process.exit(guard, :kill)

    receive do
      {:DOWN, ^cleanup_monitor, :process, ^guard, _} -> :ok
    end

    Process.demonitor(monitor, [:flush])
    flush(reply)
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

    send(reply, {reply, result, now()})
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
      {:get, key} -> Guardian.Counters.Store.get(key, opts)
      {:gets, key} -> Guardian.Counters.Store.gets(key, opts)
      {:get_many, keys} -> Guardian.Counters.Store.get_many(keys, opts)
      {:cas, key, token, value, ttl} -> Guardian.Counters.Store.cas(key, token, value, ttl, opts)
      {:incr, key, delta, ttl} -> Guardian.Counters.Store.incr(key, delta, ttl, opts)
      {:batch, operations} -> Guardian.Counters.Store.batch(operations, opts)
      _ -> {:error, :invalid_request}
    end
  catch
    _, _ -> {:error, :unavailable}
  end

  defp failed?({:error, :conflict}), do: false
  defp failed?({:pipeline, results}), do: Enum.any?(results, &failed?/1)
  defp failed?({:error, _}), do: true
  defp failed?(_), do: false
  defp suspect?({:error, :timeout}, allowance), do: allowance >= 25_000
  defp suspect?({:error, :unavailable}, _), do: true

  defp suspect?({:pipeline, results}, allowance),
    do: Enum.any?(results, &suspect?(&1, allowance))

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
      {^reply, _, _} -> flush(reply)
    after
      0 -> :ok
    end
  end
end

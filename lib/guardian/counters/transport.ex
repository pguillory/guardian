defmodule Guardian.Counters.Transport do
  @moduledoc """
  Internal owner routing and bounded pipeline transport for Counters.Client.
  Budget owns admission and settlement; this module owns dispatch and cleanup.
  """
  alias Guardian.Counters.Budget
  alias Guardian.Counters.Clock
  alias Guardian.Counters.Context
  alias Guardian.Lists

  @store_backend Application.compile_env(
                   :guardian,
                   [__MODULE__, :store_backend],
                   Guardian.Counters.Store
                 )

  @doc """
  The owner of one operation over the event's member snapshot, or the fixed
  `{:error, :invalid_request}` for a malformed operation, anchored expiry or
  routing key. Only routed operations may be passed to `dispatch/2`.

  Nothing is rescued: `owner/2` raises only on members that aren't a non-empty
  list of atoms, a programming error that Counters.Execution reports as a
  statement failure (failing open), not request data.
  """
  @spec route(tuple(), Context.t()) :: {:ok, node()} | {:error, :invalid_request}
  def route(operation, %Context{members: members}) do
    with true <- is_tuple(operation) and tuple_size(operation) in [2, 4, 5],
         kind when kind in [:get, :gets, :incr, :cas] <- elem(operation, 0),
         true <- anchored_expiry_valid?(operation),
         {:ok, routing} <- routing_key(elem(operation, 1)) do
      {:ok, owner(routing, members)}
    else
      _ -> {:error, :invalid_request}
    end
  end

  @doc """
  Runs one round's owner batches (`[{owner, operations}]`, in the order given) as
  concurrent owner pipelines within the shared budgets, returning
  `[{owner, responses}]` in the same order with one response per operation.
  """
  @spec dispatch([{node(), [tuple()]}], Context.t()) :: [{node(), [term()]}]
  def dispatch(batches, %Context{} = event) when is_list(batches) do
    results = pipelines(batches, %{}, %{}, event)
    Enum.map(batches, fn {owner, _} -> {owner, Map.fetch!(results, owner)} end)
  end

  defp pipelines(pending, running, results, event) do
    {pending, running, results} = start_pipelines(pending, running, results, event)

    try do
      if map_size(running) == 0 do
        Enum.reduce(pending, results, fn {owner, ops}, results ->
          Map.put(results, owner, errors(ops, {:error, :budget_exhausted}))
        end)
      else
        {reply, result, completed} = await_pipeline(running)
        handle = Map.fetch!(running, reply)
        cleanup_call(handle)
        result = normalize_pipeline(result, length(handle.operations))

        Budget.settle(result, handle.owner, event, handle.started, handle.reserved, completed)

        responses =
          case result do
            {:ok, responses} -> responses
            {:error, _} = error -> errors(handle.operations, error)
          end

        # Operations refused at dispatch keep their error in place.
        responses = Lists.unfilter(responses, handle.prepared, &ready?/1)

        pipelines(
          pending,
          Map.delete(running, reply),
          Map.put(results, handle.owner, responses),
          event
        )
      end
    catch
      kind, reason ->
        Enum.each(running, fn {_, handle} -> cleanup_call(handle) end)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp start_pipelines([], running, results, _event) do
    {[], running, results}
  end

  defp start_pipelines(pending, running, results, event) do
    try do
      start_pipeline(pending, running, results, event)
    catch
      kind, reason ->
        Enum.each(running, fn {_, handle} -> cleanup_call(handle) end)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp start_pipeline([{owner, operations} | rest] = pending, running, results, event) do
    case Budget.reserve(event, owner) do
      :exhausted ->
        {pending, running, results}

      :cooldown ->
        results = Map.put(results, owner, errors(operations, {:error, :cooldown}))
        start_pipelines(rest, running, results, event)

      {:ok, started, reserved} ->
        # Pending owners may wait for a reservation refund. Translate anchored
        # expiries only when their pipeline is about to dispatch, never when it queues.
        prepared = Enum.map(operations, &prepare_operation/1)
        ready = for {:ok, op} <- prepared, do: op

        if ready == [] do
          # Every operation was refused at dispatch, so its prepared error is its response.
          Budget.refund(event, reserved)
          start_pipelines(rest, running, Map.put(results, owner, prepared), event)
        else
          # Budget's started and reserved are Clock microseconds, so their sum is
          # this call's local dispatch deadline.
          handle = start_call(owner, {:batch, ready}, event.store, started + reserved)

          handle =
            Map.merge(handle, %{
              owner: owner,
              operations: ready,
              prepared: prepared,
              started: started,
              reserved: reserved,
            })

          start_pipelines(rest, Map.put(running, handle.reply, handle), results, event)
        end
    end
  end

  defp ready?(prepared) do
    match?({:ok, _}, prepared)
  end

  defp errors(operations, error) do
    Enum.map(operations, fn _ -> error end)
  end

  # Validate before admission; subtraction at dispatch must receive an integer.
  # Other operands remain Store's responsibility, including ordinary TTLs.
  defp anchored_expiry_valid?({:incr, _, _, {:expires, expiry}}) do
    is_integer(expiry)
  end

  defp anchored_expiry_valid?({:cas, _, _, _, {:expires, expiry}}) do
    is_integer(expiry)
  end

  defp anchored_expiry_valid?(_) do
    true
  end

  defp prepare_operation({:incr, key, delta, {:expires, expiry}}) do
    mutation(expiry, fn ttl -> {:incr, key, delta, ttl} end)
  end

  defp prepare_operation({:cas, key, token, value, {:expires, expiry}}) do
    mutation(expiry, fn ttl -> {:cas, key, token, value, ttl} end)
  end

  defp prepare_operation(op) do
    {:ok, op}
  end

  # Expiries are monotonic arrival milliseconds (Guardian.Counters.Arrival), not
  # Clock's microsecond coordinate.
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
        {Map.fetch!(monitors, monitor), {:error, :unavailable}, Clock.now()}
    after
      Clock.remaining_ms(deadline) ->
        {reply, _} = Enum.min_by(running, fn {_, handle} -> handle.deadline end)
        {reply, {:error, :timeout}, Clock.now()}
    end
  end

  defp normalize_pipeline({:ok, responses}, count)
       when is_list(responses) and length(responses) == count do
    {:ok, Enum.map(responses, &normalize_response/1)}
  end

  defp normalize_pipeline({:error, reason} = error, _count) when is_atom(reason) do
    error
  end

  defp normalize_pipeline(_, _count) do
    {:error, :invalid_response}
  end

  defp normalize_response(response) when response in [:ok, :not_found] do
    response
  end

  defp normalize_response({:ok, _} = response) do
    response
  end

  defp normalize_response({:ok, _, _} = response) do
    response
  end

  defp normalize_response({:error, reason} = response) when is_atom(reason) do
    response
  end

  defp normalize_response(_) do
    {:error, :invalid_response}
  end

  @doc "Rendezvous owner of {identity, group} by member name; member order never matters."
  def owner(routing_key, members) when is_list(members) and members != [] do
    Guardian.Rendezvous.owner(routing_key, members, &Atom.to_string/1)
  end

  defp routing_key({identity, group, bucket})
       when is_tuple(identity) and tuple_size(identity) == 3 and is_tuple(group) and
              is_integer(bucket) do
    {table, name, hash} = identity

    if is_binary(table) and is_binary(name) and is_binary(hash) do
      {:ok, {identity, group}}
    else
      {:error, :invalid_request}
    end
  end

  defp routing_key(_) do
    {:error, :invalid_request}
  end

  # The guard never sends over distribution. Its linked worker may be blocked in
  # distribution flow control, so either caller timeout or caller death kills both.
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
        Clock.remaining_ms(deadline) -> {{:error, :timeout}, true}
      end

    Process.exit(worker, :kill)

    if wait_for_exit? do
      receive do
        {:EXIT, ^worker, _} -> :ok
      end
    end

    send(reply, {reply, result, Clock.now()})
  end

  defp invoke(owner, operation, store, deadline) do
    duration_ms = Clock.remaining_ms(deadline)

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
      when is_integer(duration_ms) and duration_ms > 0 do
    if duration_ms <= Context.operation_ms() do
      local_operation(operation, store, duration_ms, Clock.deadline(duration_ms))
    else
      {:error, :invalid_request}
    end
  end

  def remote_operation(_, _, _) do
    {:error, :invalid_request}
  end

  defp local_operation(operation, store, timeout, deadline) do
    opts = [server: store, timeout: timeout, deadline: Clock.to_store_ms(deadline)]

    case operation do
      {:batch, operations} -> @store_backend.batch(operations, opts)
      _ -> {:error, :invalid_request}
    end
  catch
    _, _ -> {:error, :unavailable}
  end

  defp flush(reply) do
    receive do
      {^reply, _, _} -> flush(reply)
    after
      0 -> :ok
    end
  end
end

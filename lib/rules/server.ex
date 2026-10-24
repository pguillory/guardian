defmodule Rules.Server do
  @moduledoc """
  Loads, reloads, writes and publishes the rule set on this node.

  ## Startup

  `init/1` loads and validates every rule file before anything else in Guardian
  starts (it is `Main`'s first child). An unreachable store is retried with backoff
  for up to `@boot_retry_ms` (60 s), then startup is refused; a misconfigured store
  refuses startup at once. A table whose stored rules fail validation is published as
  `{:invalid, message}`, so its events fail and other tables run normally.

  If this process restarts while Guardian runs, the published set (in
  `:persistent_term`) keeps serving and the store is re-read in the background, so a
  store outage cannot take the rest of Guardian down.

  ## Reload and poll

  `reload/0` and a poll every 60 s re-read the store, fetching only objects whose ETag
  changed. A table that turns invalid at runtime keeps its previous good rules (a new
  table that is invalid is published as invalid). Nothing changes unless every
  changed table compiles; then one map is published, switching every addition, change
  and deletion at once.

  ## Writes

  Under the store's write lock (`Rules.Lock`): read the whole set from the store,
  apply the change, reject it if it adds an error the stored set did not have
  (`Rules.RuleSet.new_errors/2`), check the lease has `Rules.Lock.save_margin_ms/0`
  left, save the one file (conditional on the ETag read, or on absence), release,
  publish here, then ask every connected node to reload (up to 10 s). With a local
  folder and other nodes connected, writes are refused: each node has its own folder.

  Outcomes: `{:ok, %{errors: remaining messages, unconfirmed: nodes}}`,
  `{:error, {:rejected, messages}}`, `{:error, {:unknown, message}}` (the save may have
  happened; the lock is left to expire), or `{:error, message}`.

  ## Module pool

  Compiled modules are never reloaded in place: each change compiles into a free name
  of `Rules.Compiler`'s pool. A module the published map stops using is retired,
  and 30 s later (rows run under a 1 s limit, so no caller can still hold it) deleted
  and soft-purged; its name returns to the pool only once the purge succeeds. On a
  restart, names in the published map are in use and any other loaded name is
  retired.
  """

  use GenServer
  require Logger

  alias Rules.RuleSet

  @boot_retry_ms 60_000
  @reclaim_after_ms 30_000
  @reclaim_retry_ms 5_000
  @reload_timeout_ms 10_000
  @failure_log_table Rules.FailureLog

  def failure_log_table, do: @failure_log_table

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Callers include MCP tool calls, which run in Anubis's one shared process, so an
  # exit (a timeout, or the server restarting) becomes an error here.
  def write(table, name, source) do
    GenServer.call(__MODULE__, {:write, table, name, source}, 90_000)
  catch
    :exit, {:timeout, _} ->
      {:error,
       {:unknown, "the rule write timed out; it may have been saved; list the rules to check"}}

    :exit, _reason ->
      {:error, "the rule server is unavailable; retry"}
  end

  def reload, do: GenServer.call(__MODULE__, :reload, @reload_timeout_ms)

  @doc false
  def poll_ms, do: Application.get_env(:guardian, :rules_poll_ms, 60_000)

  @impl true
  def init(_opts) do
    if :ets.whereis(@failure_log_table) == :undefined do
      :ets.new(@failure_log_table, [:named_table, :public, :set])
    end

    case Rules.Config.store() do
      {:ok, store} ->
        Rules.put_store(store)
        # `files` is the set last activated (also the fetch cache); `stale` means the
        # published rules may not match it, so the next reload activates whatever it
        # reads even if the ETags are unchanged.
        state = %{store: store, files: %{}, stale: false, hashes: %{}, free: [], retired: %{}}

        case Rules.published() do
          nil -> boot(state)
          published -> {:ok, restart(state, published)}
        end

      {:error, message} ->
        {:stop, {:rules_store, message}}
    end
  end

  defp boot(state) do
    retry_ms = Application.get_env(:guardian, :rules_boot_retry_ms, @boot_retry_ms)
    deadline = System.monotonic_time(:millisecond) + retry_ms

    case read_with_retry(state, deadline, 1_000) do
      {:ok, files} ->
        validation = RuleSet.validate(sources(files))
        state = reserve_pool(state, MapSet.new())

        case activate(state, validation, :boot) do
          {:ok, state} ->
            log_errors(validation.errors)

            Logger.info(
              "Rules: #{map_size(files)} files for #{map_size(state.hashes)} tables " <>
                "from #{Rules.Store.describe(state.store)}"
            )

            schedule_poll()
            {:ok, %{state | files: files}}

          {:error, message} ->
            {:stop, {:rules_compile, message}}
        end

      {:error, reason} ->
        {:stop, {:rules_store, Rules.Store.reason_message(reason)}}
    end
  end

  defp read_with_retry(state, deadline, backoff) do
    case read_set(state) do
      {:error, {:unreachable, _kind}} = error ->
        if System.monotonic_time(:millisecond) + backoff < deadline do
          Logger.warning("Rules: store unreachable; retrying in #{backoff} ms")
          Process.sleep(backoff)
          read_with_retry(state, deadline, min(backoff * 2, 10_000))
        else
          error
        end

      other ->
        other
    end
  end

  defp restart(state, published) do
    in_use = published |> Map.values() |> Enum.filter(&is_atom/1) |> MapSet.new()

    hashes =
      for {table, module} <- published, is_atom(module), into: %{} do
        {table, module.hash()}
      end

    send(self(), :poll)
    %{reserve_pool(state, in_use) | hashes: hashes, stale: true}
  end

  # Rebuilds the pool from what is loaded: names in use stay in use, any other loaded
  # name (left by an earlier instance of this process) is retired, never reused while
  # loaded; the rest are free.
  defp reserve_pool(state, in_use) do
    {loaded, free} =
      Rules.Compiler.names()
      |> Enum.reject(&(&1 in in_use))
      |> Enum.split_with(&(:code.is_loaded(&1) != false or :erlang.check_old_code(&1)))

    Enum.each(loaded, &schedule_reclaim(&1, @reclaim_after_ms))
    %{state | free: free, retired: Map.new(loaded, &{&1, :pending})}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case reload_state(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, message, state} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:write, table, name, source}, _from, state) do
    {reply, state} = write_rule(state, table, name, source)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case reload_state(state) do
        {:ok, state} -> state
        {:error, message, state} -> log_poll_failure(state, message)
      end

    schedule_poll()
    {:noreply, state}
  end

  def handle_info({:reclaim, module}, state) do
    {:noreply, reclaim(state, module)}
  end

  ## Reading

  # The whole set from the store: %{key => %{etag, source}}. Sources whose ETag is
  # unchanged are reused; others are fetched bound to the listed ETag, and a change
  # between the list and a fetch restarts the read (at most 3 times).
  defp read_set(state, attempts \\ 3) do
    with {:ok, objects} <- Rules.Store.list(state.store) do
      objects
      |> Enum.filter(&(RuleSet.parse_key(&1.key) != :ignore))
      |> Enum.reduce_while({:ok, %{}}, fn object, {:ok, files} ->
        case fetch(state, object) do
          {:ok, file} -> {:cont, {:ok, Map.put(files, object.key, file)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
    |> case do
      {:error, changed} when changed in [:precondition_failed, :not_found] and attempts > 1 ->
        read_set(state, attempts - 1)

      {:error, changed} when changed in [:precondition_failed, :not_found] ->
        {:error, {:unreachable, "rule files kept changing during the read"}}

      other ->
        other
    end
  end

  defp fetch(state, %{key: key, etag: etag, size: size}) do
    cached = Map.get(state.files, key)

    cond do
      cached != nil and cached.etag == etag ->
        {:ok, cached}

      match?({:error, _}, RuleSet.parse_key(key)) ->
        {:ok, %{etag: etag, source: ""}}

      size > RuleSet.max_file_bytes() ->
        {:ok, %{etag: etag, source: :too_large}}

      true ->
        case Rules.Store.get(state.store, key, etag) do
          {:ok, source, _meta} -> {:ok, %{etag: etag, source: source}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp sources(files), do: Map.new(files, fn {key, file} -> {key, file.source} end)

  defp reload_state(state) do
    case read_set(state) do
      {:ok, files} ->
        if not state.stale and etags(files) == etags(state.files) do
          {:ok, state}
        else
          validation = RuleSet.validate(sources(files))
          log_errors(validation.errors)

          case activate(state, validation, :runtime) do
            {:ok, state} -> {:ok, %{state | files: files, stale: false}}
            {:error, message} -> {:error, message, state}
          end
        end

      {:error, reason} ->
        {:error, Rules.Store.reason_message(reason), state}
    end
  end

  defp etags(files), do: Map.new(files, fn {key, file} -> {key, file.etag} end)

  ## Writing

  defp write_rule(state, table, name, source) do
    key = RuleSet.key(table, name)

    cond do
      (path_error = RuleSet.check_path(table, name)) != :ok ->
        {:error, message} = path_error
        {{:error, {:rejected, [message]}}, state}

      is_binary(source) and byte_size(source) > RuleSet.max_file_bytes() ->
        {{:error, {:rejected, ["#{key}: is over #{RuleSet.max_file_bytes()} bytes"]}}, state}

      Rules.Store.local?(state.store) and Node.list() != [] ->
        {{:error,
          "rules are in a local folder, which each node has its own copy of; " <>
            "a cluster needs an S3 rule store"}, state}

      true ->
        case Rules.Lock.acquire(state.store, "#{node()}") do
          {:ok, lock} ->
            locked_write(state, lock, key, source)

          {:error, :busy} ->
            {{:error, "another rule write is in progress; retry"}, state}

          {:error, reason} ->
            {{:error, Rules.Store.reason_message(reason)}, state}
        end
    end
  end

  defp locked_write(state, lock, key, source) do
    case read_set(state) do
      {:ok, files} ->
        # `state.files` stays the set last activated until a save activates `files`:
        # a reload compares ETags with it, so advancing it here without activating
        # would make the next reload skip rules another writer saved.
        before = RuleSet.validate(sources(files))

        after_sources =
          case source do
            :delete -> Map.delete(sources(files), key)
            source -> Map.put(sources(files), key, source)
          end

        validation = RuleSet.validate(after_sources)
        new_errors = RuleSet.new_errors(before.errors, validation.errors)

        cond do
          source == :delete and not Map.has_key?(files, key) ->
            release(lock)
            {{:error, "no rule file #{key}"}, state}

          new_errors != [] ->
            release(lock)
            {{:error, {:rejected, Enum.map(new_errors, & &1.message)}}, state}

          Rules.Lock.remaining_ms(lock) < Rules.Lock.save_margin_ms() ->
            release(lock)
            {{:error, "the write lock's lease ran short; retry"}, state}

          true ->
            save(state, lock, key, source, files, validation)
        end

      {:error, reason} ->
        release(lock)
        {{:error, Rules.Store.reason_message(reason)}, state}
    end
  end

  defp save(state, lock, key, source, files, validation) do
    result =
      case source do
        :delete ->
          with :ok <- Rules.Store.delete(state.store, key), do: {:ok, nil}

        source ->
          condition =
            case Map.fetch(files, key) do
              {:ok, file} -> {:etag, file.etag}
              :error -> :absent
            end

          Rules.Store.put(state.store, key, source, condition)
      end

    case result do
      {:ok, etag} ->
        release(lock)
        Logger.info("Rules: #{if source == :delete, do: "deleted", else: "wrote"} #{key}")

        files =
          if source == :delete,
            do: Map.delete(files, key),
            else: Map.put(files, key, %{etag: etag, source: source})

        {state, local_error} =
          case activate(state, validation, :runtime) do
            {:ok, state} -> {%{state | files: files, stale: false}, nil}
            {:error, message} -> {%{state | stale: true}, message}
          end

        unconfirmed = broadcast_reload()
        unconfirmed = if local_error, do: [node() | unconfirmed], else: unconfirmed

        {{:ok, %{errors: Enum.map(validation.errors, & &1.message), unconfirmed: unconfirmed}},
         state}

      {:error, {:unknown, _kind} = reason} ->
        # The save may have happened: leave the lock to expire, so the next writer
        # starts well after this request, and validates whatever it finds.
        Logger.warning("Rules: writing #{key}: #{Rules.Store.reason_message(reason)}")

        {{:error,
          {:unknown,
           "#{Rules.Store.reason_message(reason)}; #{key} may have been saved; list the rules to check"}},
         %{state | stale: true}}

      {:error, :precondition_failed} ->
        release(lock)
        {{:error, "#{key} changed concurrently; retry"}, state}

      {:error, reason} ->
        release(lock)
        {{:error, Rules.Store.reason_message(reason)}, state}
    end
  end

  defp release(lock) do
    case Rules.Lock.release(lock) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Rules: releasing the write lock: #{Rules.Store.reason_message(reason)}")
    end
  end

  # Asks every other connected node to reload; returns the nodes that did not confirm.
  defp broadcast_reload do
    nodes = Node.list()

    nodes
    |> :erpc.multicall(Rules, :reload, [], @reload_timeout_ms)
    |> Enum.zip(nodes)
    |> Enum.reject(fn {result, _node} -> result == {:ok, :ok} end)
    |> Enum.map(fn {_result, node} -> node end)
  end

  ## Activation

  defp activate(state, validation, mode) do
    published = Rules.published() || %{}

    {targets, to_compile} =
      Enum.reduce(validation.tables, {%{}, []}, fn {table, result}, {targets, to_compile} ->
        current = Map.get(published, table)

        case result do
          {:ok, plan} ->
            if is_atom(current) and current != nil and state.hashes[table] == plan.hash do
              {Map.put(targets, table, current), to_compile}
            else
              {targets, [plan | to_compile]}
            end

          {:error, errors} ->
            if mode == :runtime and is_atom(current) and current != nil do
              {Map.put(targets, table, current), to_compile}
            else
              {Map.put(targets, table, {:invalid, invalid_message(errors)}), to_compile}
            end
        end
      end)

    case compile_all(state, Enum.reverse(to_compile), []) do
      {:ok, compiled, free} ->
        tables =
          Enum.reduce(compiled, targets, fn {plan, module}, acc ->
            Map.put(acc, plan.table, module)
          end)

        Rules.publish(tables)

        hashes =
          for {table, module} <- tables, is_atom(module), into: %{} do
            {table, module.hash()}
          end

        in_use = tables |> Map.values() |> Enum.filter(&is_atom/1) |> MapSet.new()

        retiring =
          published
          |> Map.values()
          |> Enum.filter(&(is_atom(&1) and &1 not in in_use))
          |> Enum.uniq()

        Enum.each(retiring, &schedule_reclaim(&1, @reclaim_after_ms))
        retired = Enum.reduce(retiring, state.retired, &Map.put(&2, &1, :pending))

        {:ok, %{state | free: free, hashes: hashes, retired: retired}}

      {:error, message} ->
        {:error, message}
    end
  end

  defp compile_all(state, [], compiled), do: {:ok, compiled, state.free}

  defp compile_all(%{free: []} = state, [_ | _], compiled) do
    discard(compiled)
    _ = state
    {:error, "no free rule module names; retrying on the next poll"}
  end

  defp compile_all(%{free: [module | free]} = state, [plan | plans], compiled) do
    case Rules.Compiler.compile(module, plan) do
      :ok ->
        compile_all(%{state | free: free}, plans, [{plan, module} | compiled])

      {:error, kind} ->
        discard([{plan, module} | compiled])
        {:error, "compiling the rules for #{plan.table} failed (#{kind})"}
    end
  end

  # Unloads modules that were compiled but never published (nothing has called them),
  # so their names, still in the caller's free list, can be used again.
  defp discard(compiled) do
    Enum.each(compiled, fn {_plan, module} ->
      :code.delete(module)
      :code.purge(module)
    end)
  end

  defp invalid_message([first | rest]) do
    case rest do
      [] -> first.message
      _ -> "#{first.message} (and #{length(rest)} more)"
    end
  end

  ## Reclaiming retired modules

  defp schedule_reclaim(module, @reclaim_after_ms) do
    after_ms = Application.get_env(:guardian, :rules_reclaim_after_ms, @reclaim_after_ms)
    Process.send_after(self(), {:reclaim, module}, after_ms)
  end

  defp schedule_reclaim(module, after_ms) do
    Process.send_after(self(), {:reclaim, module}, after_ms)
  end

  defp reclaim(state, module) do
    case Map.get(state.retired, module) do
      nil ->
        state

      status ->
        # Delete once (making the code old), then soft-purge until no process runs it.
        if status == :pending, do: :code.delete(module)

        if :code.soft_purge(module) do
          %{state | retired: Map.delete(state.retired, module), free: state.free ++ [module]}
        else
          schedule_reclaim(module, @reclaim_retry_ms)
          %{state | retired: Map.put(state.retired, module, :deleted)}
        end
    end
  end

  ## Logging

  defp schedule_poll, do: Process.send_after(self(), :poll, poll_ms())

  defp log_errors([]), do: :ok

  defp log_errors(errors) do
    Logger.warning(
      "Rules: #{length(errors)} invalid: " <>
        Enum.map_join(Enum.take(errors, 5), "; ", & &1.message)
    )
  end

  defp log_poll_failure(state, message) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state, :poll_logged_at) do
      at when is_integer(at) and now - at < 600_000 ->
        state

      _ ->
        Logger.warning("Rules: reloading failed: #{message}")
        Map.put(state, :poll_logged_at, now)
    end
  end
end

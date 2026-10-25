defmodule Guardian.Rules.Server do
  @moduledoc """
  Loads, reloads, writes and publishes the rule set on this node.

  ## Startup

  `init/1` loads and validates every rule file before anything else in Guardian
  starts (it is `Guardian.Application`'s first child). An unreachable or rate-limiting (HTTP 429)
  store is retried with backoff for up to `@boot_retry_ms` (60 s), then startup is
  refused; a misconfigured store refuses startup at once. A table whose stored rules
  fail validation is published as `{:invalid, message}`, so its events fail and
  other tables run normally.

  If this process restarts while Guardian runs, the published set (in
  `:persistent_term`) keeps serving and the store is re-read in the background, so a
  store outage cannot take the rest of Guardian down.

  ## Reload and poll

  `reload/0` and a poll every 60 s re-read the store, fetching only objects whose ETag
  changed. Activation selects prior good plans for invalid dependency components
  (a new table that is invalid is published as invalid). Nothing changes unless every
  changed table compiles; then one map is published, switching every addition, change
  and deletion at once.

  ## Writes

  Under the store's write lock (`Guardian.Rules.Lock`): read the whole set from the store,
  apply the change, reject it if it adds an error the stored set did not have
  (`Guardian.Rules.RuleSet.new_errors/2`), check the lease has `Guardian.Rules.Lock.save_margin_ms/0`
  left, save the one file (conditional on the ETag read, or on absence), release,
  publish here, then ask every connected node to reload (up to 10 s). With a local
  folder and other nodes connected, writes are refused: each node has its own folder.

  Outcomes: `{:ok, %{errors: remaining messages, unconfirmed: nodes}}`,
  `{:error, {:rejected, messages}}`, `{:error, {:unknown, message}}` (the save may have
  happened; the lock is left to expire), or `{:error, message}`.

  ## Module pool

  Compiled modules are never reloaded in place: each change compiles into a free name
  of `Guardian.Rules.Compiler`'s pool. A module the published map stops using is retired,
  and 30 s later (rows run under a 1 s limit, so no caller can still hold it) deleted
  and soft-purged; its name returns to the pool only once the purge succeeds. On a
  restart, names in the published map are in use and any other loaded name is
  retired. Each generated module exposes its exact immutable plan; activation
  recovers previous plans from those modules, including after a Server restart,
  without reading the store or maintaining a separate history/cache of plans.

  ## Status and crash reports

  Rule text never appears in a crash report or in this server's part of
  `:sys.get_status/1` (`format_status/1`): every file, in the state or in a past
  state in the debug log, keeps only its ETag, and a write message's source is
  replaced by `:redacted`. Plans and bare steps are redacted too, including AST
  constants as well as canonical source. `init/1`, `handle_call/3` and `handle_info/2`
  re-raise whatever they raise as an error naming only the kind, with a stack of arities,
  since an exception's message or fields and the top frame's arguments can hold a
  source (the report's stack is not passed through `format_status/1`). `write/3`
  turns the call's exit into an error without logging the exit reason, which
  carries the message. With `:sys.log/2` turned on, `:sys.get_status/1` also returns
  OTP's raw debug log beside the formatted status, unredacted; that needs a remote
  shell, which `:sys.get_state/1` already gives everything.
  """

  use GenServer
  require Logger

  alias Guardian.Rules.RuleSet

  @boot_retry_ms 60_000
  @reclaim_after_ms 30_000
  @reclaim_retry_ms 5_000
  @reload_timeout_ms 10_000
  @failure_log_table Guardian.Rules.FailureLog

  def failure_log_table do
    @failure_log_table
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

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

  def reload do
    GenServer.call(__MODULE__, :reload, @reload_timeout_ms)
  end

  @doc false
  def poll_ms do
    Application.get_env(:guardian, :rules_poll_ms, 60_000)
  end

  @impl true
  def init(opts) do
    scrubbed(fn -> start(opts) end)
  end

  defp start(_opts) do
    if :ets.whereis(@failure_log_table) == :undefined do
      :ets.new(@failure_log_table, [:named_table, :public, :set])
    end

    case Guardian.Rules.Config.store() do
      {:ok, store} ->
        Guardian.Rules.put_store(store)
        # `files` is the set last activated (also the fetch cache); `stale` means the
        # published rules may not match it, so the next reload activates whatever it
        # reads even if the ETags are unchanged.
        state = %{store: store, files: %{}, stale: false, free: [], retired: %{}}

        case Guardian.Rules.published() do
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
        preparation = prepare(sources(files))
        state = reserve_pool(state, MapSet.new())

        case activate(state, preparation) do
          {:ok, state, _errors} ->
            table_count =
              Enum.count(Guardian.Rules.published(), fn {_table, module} -> is_atom(module) end)

            Logger.info(
              "Rules: #{map_size(files)} files for #{table_count} tables " <>
                "from #{Guardian.Rules.Store.describe(state.store)}"
            )

            schedule_poll()
            {:ok, %{state | files: files}}

          {:error, message, _errors} ->
            {:stop, {:rules_compile, message}}
        end

      {:error, reason} ->
        {:stop, {:rules_store, Guardian.Rules.Store.reason_message(reason)}}
    end
  end

  defp read_with_retry(state, deadline, backoff) do
    case read_set(state) do
      {:error, {:unreachable, kind}} = error ->
        if System.monotonic_time(:millisecond) + backoff < deadline do
          Logger.warning("Rules: store unreachable (#{kind}); retrying in #{backoff} ms")
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

    send(self(), :poll)
    %{reserve_pool(state, in_use) | stale: true}
  end

  # Rebuilds the pool from what is loaded: names in use stay in use, any other loaded
  # name (left by an earlier instance of this process) is retired, never reused while
  # loaded; the rest are free.
  defp reserve_pool(state, in_use) do
    {loaded, free} =
      Guardian.Rules.Compiler.names()
      |> Enum.reject(&(&1 in in_use))
      |> Enum.split_with(&(:code.is_loaded(&1) != false or :erlang.check_old_code(&1)))

    Enum.each(loaded, &schedule_reclaim(&1, @reclaim_after_ms))
    %{state | free: free, retired: Map.new(loaded, &{&1, :pending})}
  end

  # Every callback runs through scrubbed/1, so a crash report never shows a rule
  # source from an exception or a stack frame's arguments.
  @impl true
  def handle_call(request, from, state) do
    scrubbed(fn -> call(request, from, state) end)
  end

  @impl true
  def handle_info(message, state) do
    scrubbed(fn -> info(message, state) end)
  end

  defp call(:reload, _from, state) do
    case reload_state(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, message, state} -> {:reply, {:error, message}, state}
    end
  end

  defp call({:write, table, name, source}, _from, state) do
    {reply, state} = write_rule(state, table, name, source)
    {:reply, reply, state}
  end

  defp info(:poll, state) do
    state =
      case reload_state(state) do
        {:ok, state} -> state
        {:error, message, state} -> log_poll_failure(state, message)
      end

    schedule_poll()
    {:noreply, state}
  end

  defp info({:reclaim, module}, state) do
    {:noreply, reclaim(state, module)}
  end

  ## Reading

  # The whole set from the store: %{key => %{etag, source}}. Sources whose ETag is
  # unchanged are reused; others are fetched bound to the listed ETag, and a change
  # between the list and a fetch restarts the read (at most 3 times).
  defp read_set(state, attempts \\ 3) do
    with {:ok, objects} <- Guardian.Rules.Store.list(state.store) do
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
        case Guardian.Rules.Store.get(state.store, key, etag) do
          {:ok, source, _meta} -> {:ok, %{etag: etag, source: source}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp sources(files) do
    Map.new(files, fn {key, file} -> {key, file.source} end)
  end

  # Whole-set preparation is shared by every admission path.
  defp prepare(sources) do
    RuleSet.prepare(sources)
  end

  defp reload_state(state) do
    case read_set(state) do
      {:ok, files} ->
        if not state.stale and etags(files) == etags(state.files) do
          {:ok, state}
        else
          case activate(state, prepare(sources(files))) do
            {:ok, state, _errors} -> {:ok, %{state | files: files, stale: false}}
            {:error, message, _errors} -> {:error, message, state}
          end
        end

      {:error, reason} ->
        {:error, Guardian.Rules.Store.reason_message(reason), state}
    end
  end

  defp etags(files) do
    Map.new(files, fn {key, file} -> {key, file.etag} end)
  end

  ## Writing

  defp write_rule(state, table, name, source) do
    key = RuleSet.key(table, name)

    cond do
      (path_error = RuleSet.check_path(table, name)) != :ok ->
        {:error, message} = path_error
        {{:error, {:rejected, [message]}}, state}

      is_binary(source) and byte_size(source) > RuleSet.max_file_bytes() ->
        {{:error, {:rejected, ["#{key}: is over #{RuleSet.max_file_bytes()} bytes"]}}, state}

      Guardian.Rules.Store.local?(state.store) and Node.list() != [] ->
        {{:error,
          "rules are in a local folder, which each node has its own copy of; " <>
            "a cluster needs an S3 rule store"}, state}

      true ->
        case Guardian.Rules.Lock.acquire(state.store, "#{node()}") do
          {:ok, lock} ->
            locked_write(state, lock, key, source)

          {:error, :busy} ->
            {{:error, "another rule write is in progress; retry"}, state}

          {:error, reason} ->
            {{:error, Guardian.Rules.Store.reason_message(reason)}, state}
        end
    end
  end

  defp locked_write(state, lock, key, source) do
    case read_set(state) do
      {:ok, files} ->
        # `state.files` stays the set last activated until a save activates `files`:
        # a reload compares ETags with it, so advancing it here without activating
        # would make the next reload skip rules another writer saved.
        before = prepare(sources(files))

        after_sources =
          case source do
            :delete -> Map.delete(sources(files), key)
            source -> Map.put(sources(files), key, source)
          end

        validation = prepare(after_sources)
        # Admission compares stored-set errors, never activation's retention or
        # deferral diagnostics: broken sets must remain repairable file by file.
        new_errors = RuleSet.new_errors(before.errors, validation.errors)

        cond do
          source == :delete and not Map.has_key?(files, key) ->
            release(lock)
            {{:error, "no rule file #{key}"}, state}

          new_errors != [] ->
            release(lock)
            {{:error, {:rejected, Enum.map(new_errors, & &1.message)}}, state}

          Guardian.Rules.Lock.remaining_ms(lock) < Guardian.Rules.Lock.save_margin_ms() ->
            release(lock)
            {{:error, "the write lock's lease ran short; retry"}, state}

          true ->
            save(state, lock, key, source, files, validation)
        end

      {:error, reason} ->
        release(lock)
        {{:error, Guardian.Rules.Store.reason_message(reason)}, state}
    end
  end

  defp save(state, lock, key, source, files, validation) do
    result =
      case source do
        :delete ->
          with :ok <- Guardian.Rules.Store.delete(state.store, key), do: {:ok, nil}

        source ->
          condition =
            case Map.fetch(files, key) do
              {:ok, file} -> {:etag, file.etag}
              :error -> :absent
            end

          Guardian.Rules.Store.put(state.store, key, source, condition)
      end

    case result do
      {:ok, etag} ->
        release(lock)
        Logger.info("Rules: #{if source == :delete, do: "deleted", else: "wrote"} #{key}")

        files =
          if source == :delete,
            do: Map.delete(files, key),
            else: Map.put(files, key, %{etag: etag, source: source})

        {state, local_error, errors} =
          case activate(state, validation) do
            {:ok, state, errors} -> {%{state | files: files, stale: false}, nil, errors}
            {:error, message, errors} -> {%{state | stale: true}, message, errors}
          end

        unconfirmed = broadcast_reload()
        unconfirmed = if local_error, do: [node() | unconfirmed], else: unconfirmed

        {{:ok, %{errors: Enum.map(errors, & &1.message), unconfirmed: unconfirmed}}, state}

      {:error, {:unknown, _kind} = reason} ->
        # The save may have happened: leave the lock to expire, so the next writer
        # starts well after this request, and validates whatever it finds.
        Logger.warning("Rules: writing #{key}: #{Guardian.Rules.Store.reason_message(reason)}")

        {{:error,
          {:unknown,
           "#{Guardian.Rules.Store.reason_message(reason)}; #{key} may have been saved; list the rules to check"}},
         %{state | stale: true}}

      {:error, :precondition_failed} ->
        release(lock)
        {{:error, "#{key} changed concurrently; retry"}, state}

      {:error, reason} ->
        release(lock)
        {{:error, Guardian.Rules.Store.reason_message(reason)}, state}
    end
  end

  defp release(lock) do
    case Guardian.Rules.Lock.release(lock) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Rules: releasing the write lock: #{Guardian.Rules.Store.reason_message(reason)}"
        )
    end
  end

  # Asks every other connected node to reload; returns the nodes that did not confirm.
  defp broadcast_reload do
    nodes = Node.list()

    nodes
    |> :erpc.multicall(Guardian.Rules, :reload, [], @reload_timeout_ms)
    |> Enum.zip(nodes)
    |> Enum.reject(fn {result, _node} -> result == {:ok, :ok} end)
    |> Enum.map(fn {_result, node} -> node end)
  end

  ## Activation

  defp activate(state, preparation) do
    published = Guardian.Rules.published() || %{}
    previous = published_plans(published)
    selected = Guardian.Rules.Activation.select(preparation, previous)
    errors = activation_errors(preparation, selected)
    log_errors(errors)

    {targets, to_compile} =
      Enum.reduce(selected.tables, {%{}, []}, fn {table, result}, {targets, to_compile} ->
        current = Map.get(published, table)

        case result do
          {:ok, plan} ->
            if is_atom(current) and current != nil and current.hash() == plan.hash do
              {Map.put(targets, table, current), to_compile}
            else
              {targets, [plan | to_compile]}
            end

          {:error, errors} ->
            {Map.put(targets, table, {:invalid, invalid_message(errors)}), to_compile}
        end
      end)

    case compile_all(state, Enum.reverse(to_compile), []) do
      {:ok, compiled, free} ->
        tables =
          Enum.reduce(compiled, targets, fn {plan, module}, acc ->
            Map.put(acc, plan.table, module)
          end)

        Guardian.Rules.publish(tables)

        in_use = tables |> Map.values() |> Enum.filter(&is_atom/1) |> MapSet.new()

        retiring =
          published
          |> Map.values()
          |> Enum.filter(&(is_atom(&1) and &1 not in in_use))
          |> Enum.uniq()

        Enum.each(retiring, &schedule_reclaim(&1, @reclaim_after_ms))
        retired = Enum.reduce(retiring, state.retired, &Map.put(&2, &1, :pending))

        {:ok, %{state | free: free, retired: retired}, errors}

      {:error, message} ->
        {:error, message, errors}
    end
  end

  # Published modules are the sole source of truth, also after a Server restart.
  # The fixed pool bounds metadata lifetime; no per-reload registry accumulates.
  defp published_plans(published) do
    for {table, module} <- published, is_atom(module), into: %{}, do: {table, module.plan()}
  end

  defp activation_errors(preparation, selected) do
    selected_errors =
      Enum.flat_map(selected.tables, fn
        {_table, {:error, errors}} -> errors
        _ -> []
      end)

    (preparation.errors ++ selected_errors)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.file, &1.line || 0, &1.kind})
  end

  defp compile_all(state, [], compiled) do
    {:ok, compiled, state.free}
  end

  defp compile_all(%{free: []} = state, [_ | _], compiled) do
    discard(compiled)
    _ = state
    {:error, "no free rule module names; retrying on the next poll"}
  end

  defp compile_all(%{free: [module | free]} = state, [plan | plans], compiled) do
    case Guardian.Rules.Compiler.compile(module, plan) do
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

  ## Status and crash reports

  @impl true
  def format_status(status) do
    Map.new(status, fn {key, value} -> {key, redact(value)} end)
  end

  # However nested, in the state, the message, or the debug log (whose entries hold
  # past states and messages): a write request's source, and each file's source.
  defp redact({:write, table, name, source}) when is_binary(source) do
    {:write, table, name, :redacted}
  end

  defp redact(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()
  end

  defp redact([head | tail]) do
    [redact(head) | redact(tail)]
  end

  defp redact(%Guardian.Rules.Plan{} = plan) do
    Map.take(plan, [:table, :hash, :resolved?])
  end

  defp redact(%step{})
       when step in [
              Guardian.Rules.Step.Set,
              Guardian.Rules.Step.Unset,
              Guardian.Rules.Step.Track,
              Guardian.Rules.Step.Lookup,
            ] do
    :redacted
  end

  defp redact(%_{} = struct) do
    struct
  end

  defp redact(%{etag: _, source: _} = file) do
    Map.take(file, [:etag])
  end

  defp redact(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, redact(v)} end)
  end

  defp redact(term) do
    term
  end

  # Re-raises anything a callback raises, throws or exits with as an error naming only
  # its kind, with a stack of arities and locations: the exception's message and
  # fields, and the top frame's arguments, can hold a source.
  defp scrubbed(fun) do
    fun.()
  catch
    kind, reason ->
      stack = Enum.map(__STACKTRACE__, &redact_frame/1)
      message = "Guardian.Rules.Server crashed: #{kind} #{reason_kind(reason)} (details redacted)"
      :erlang.raise(:error, %RuntimeError{message: message}, stack)
  end

  defp reason_kind(%{__exception__: true, __struct__: module}) do
    inspect(module)
  end

  defp reason_kind(atom) when is_atom(atom) do
    inspect(atom)
  end

  defp reason_kind(tuple)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)) do
    inspect(elem(tuple, 0))
  end

  defp reason_kind(_reason) do
    "term"
  end

  defp redact_frame({module, function, args, location}) do
    arity = if is_list(args), do: length(args), else: args
    {module, function, arity, Keyword.take(location, [:file, :line])}
  end

  defp redact_frame(frame) do
    frame
  end

  ## Logging

  defp schedule_poll do
    Process.send_after(self(), :poll, poll_ms())
  end

  defp log_errors([]) do
    :ok
  end

  # By file, line and kind only: a message can quote rule text (the token a parse
  # error got, say), and rules can hold secrets. The rule tools return the messages.
  defp log_errors(errors) do
    Logger.warning(
      "Rules: #{length(errors)} invalid: " <>
        Enum.map_join(Enum.take(errors, 5), "; ", &error_location/1)
    )
  end

  defp error_location(%{file: file, line: nil, kind: kind}) do
    "#{file} (#{kind})"
  end

  defp error_location(%{file: file, line: line, kind: kind}) do
    "#{file} line #{line} (#{kind})"
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

defmodule Guardian.Rules.Server do
  @moduledoc """
  Loads, reloads, writes and publishes the rule set on this node.

  ## Startup

  `init/1` loads and validates every rule file before anything else in Guardian
  starts (it is `Guardian.Application`'s first child). An unreachable or rate-limiting
  (HTTP 429) store is retried with backoff (up to 10 s apart) for as long as it takes,
  so Guardian is not up until the store answers; a misconfigured store refuses
  startup at once. A table whose stored rules fail validation is published as
  `{:invalid, message}`, so its events fail and other tables run normally.

  If this process restarts while Guardian runs, the published set (in
  `:persistent_term`) keeps serving and the store is re-read in the background, so a
  store outage cannot take the rest of Guardian down.

  ## Reload and poll

  `reload/0` and a poll every 60 s re-read the store, fetching only objects whose ETag
  changed. Activation is the same as at startup: a table whose stored rules fail
  validation (or whose LOOKUP reads a counter of such a table) is published as
  invalid, with no last good rules kept. Nothing changes unless every changed table
  compiles; then one map is published, switching every addition, change and deletion
  at once.

  ## Writes

  Under the store's write lock (a `Guardian.ObjectStore.Lock` on
  `lock_key/0`): read the whole set from the store,
  apply the change, reject it if it adds an error the stored set did not have
  (`Guardian.Rules.RuleSet.new_errors/2`), check the lease has `save_margin_ms/0`
  left, save the one file (conditional on the ETag read, or on absence), release,
  publish here, then ask every connected node to reload (up to 10 s). With a local
  folder and other nodes connected, writes are refused: each node has its own folder.
  Store sharing is declared by `Guardian.ObjectStore.shared?/1`.

  The lock is tried once: if another writer holds it, or a lock left by an interrupted
  write has not yet expired (the 120 s lease), the write fails at once as `:busy`,
  having changed nothing. Whether to try again is the caller's choice.

  Outcomes: `{:ok, %{errors: remaining messages, unconfirmed: nodes}}`,
  `{:error, {:rejected, messages}}`, `{:error, :busy}`, `{:error, {:unknown, message}}`
  (the save may have happened; the lock is left to expire), or `{:error, message}`.

  ## Module pool

  `Guardian.Rules.Publisher` owns activation, publication and the module pool,
  synchronously inside this server's callbacks. Server holds its pool value and
  forwards reclamation messages. After a Server restart, Publisher reserves the
  published modules' names; see its module documentation for the compilation and
  reclamation lifecycle.

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

  alias Guardian.ObjectStore
  alias Guardian.ObjectStore.Lock
  alias Guardian.Rules
  alias Guardian.Rules.Publisher
  alias Guardian.Rules.RuleSet

  @reload_timeout_ms 10_000
  @failure_log_table Guardian.Rules.FailureLog
  @lock_key "_write.lock"
  @lock_lease_ms 120_000
  # Well over Guardian.ObjectStore.S3.write_deadline_ms/0 for the one S3 write a
  # holder makes, including time before the write starts. ServerTest checks that
  # dependency against the defaults; reconsider this margin when the deadline grows.
  @save_margin_ms 80_000

  @doc false
  def lock_key do
    @lock_key
  end

  # Tests shorten the lease and the margin through app env.
  @doc false
  def lock_lease_ms do
    Application.get_env(:guardian, :rules_lock_lease_ms, @lock_lease_ms)
  end

  @doc false
  def save_margin_ms do
    Application.get_env(:guardian, :rules_save_margin_ms, @save_margin_ms)
  end

  def failure_log_table do
    @failure_log_table
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Callers include MCP tool calls, which run in Anubis's per-request tasks, so an exit
  # (a timeout, or the server restarting) becomes an error here rather than a crash.
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
        Rules.put_store(store)
        # `files` is the set last activated (also the fetch cache); `stale` means the
        # published rules may not match it, so the next reload activates whatever it
        # reads even if the ETags are unchanged.
        state = %{store: store, files: %{}, stale: false, publisher: nil}

        case Rules.published() do
          nil -> boot(state)
          published -> {:ok, restart(state, published)}
        end

      {:error, message} ->
        {:stop, {:rules_store, message}}
    end
  end

  defp boot(state) do
    case read_with_retry(state, 1_000) do
      {:ok, files} ->
        preparation = prepare(sources(files))
        state = %{state | publisher: Publisher.new(%{})}

        case activate(state, preparation) do
          {:ok, state, _errors} ->
            table_count =
              Enum.count(Rules.published(), fn {_table, module} -> is_atom(module) end)

            Logger.info(
              "Rules: #{map_size(files)} files for #{table_count} tables " <>
                "from #{ObjectStore.describe(state.store)}"
            )

            schedule_poll()
            {:ok, %{state | files: files}}

          {:error, message, _errors} ->
            {:stop, {:rules_compile, message}}
        end

      {:error, reason} ->
        {:stop, {:rules_store, ObjectStore.reason_message(reason)}}
    end
  end

  # Retries an unreachable store indefinitely: Guardian waits for its rules rather
  # than starting without them.
  defp read_with_retry(state, backoff) do
    case read_set(state) do
      {:error, {:unreachable, kind}} ->
        Logger.warning("Rules: store unreachable (#{kind}); retrying in #{backoff} ms")
        Process.sleep(backoff)
        read_with_retry(state, min(backoff * 2, 10_000))

      other ->
        other
    end
  end

  defp restart(state, published) do
    send(self(), :poll)
    %{state | publisher: Publisher.new(published), stale: true}
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
    {:noreply, %{state | publisher: Publisher.reclaim(state.publisher, module)}}
  end

  ## Reading

  # The whole set from the store: %{key => %{etag, source}}. Sources whose ETag is
  # unchanged are reused; others are fetched bound to the listed ETag, and a change
  # between the list and a fetch restarts the read (at most 3 times).
  defp read_set(state, attempts \\ 3) do
    with {:ok, objects} <- ObjectStore.list(state.store) do
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
        case ObjectStore.get(state.store, key, etag) do
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
        {:error, ObjectStore.reason_message(reason), state}
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

      not ObjectStore.shared?(state.store) and Node.list() != [] ->
        {{:error,
          "rules are in a local folder, which each node has its own copy of; " <>
            "a cluster needs an S3 rule store"}, state}

      true ->
        case Lock.acquire(state.store, lock_key(), "#{node()}", lease_ms: lock_lease_ms()) do
          {:ok, lock} ->
            locked_write(state, lock, key, source)

          {:error, :busy} ->
            {{:error, :busy}, state}

          {:error, reason} ->
            {{:error, ObjectStore.reason_message(reason)}, state}
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
        # Admission compares only the errors this write adds to the stored set:
        # broken sets must remain repairable file by file.
        new_errors = RuleSet.new_errors(before.errors, validation.errors)

        cond do
          source == :delete and not Map.has_key?(files, key) ->
            release(lock)
            {{:error, "no rule file #{key}"}, state}

          new_errors != [] ->
            release(lock)
            {{:error, {:rejected, Enum.map(new_errors, & &1.message)}}, state}

          Lock.remaining_ms(lock) < save_margin_ms() ->
            release(lock)
            {{:error, "the write lock's lease ran short; retry"}, state}

          true ->
            save(state, lock, key, source, files, validation)
        end

      {:error, reason} ->
        release(lock)
        {{:error, ObjectStore.reason_message(reason)}, state}
    end
  end

  defp save(state, lock, key, source, files, validation) do
    result =
      case source do
        :delete ->
          with :ok <- ObjectStore.delete(state.store, key), do: {:ok, nil}

        source ->
          condition =
            case Map.fetch(files, key) do
              {:ok, file} -> {:etag, file.etag}
              :error -> :absent
            end

          ObjectStore.put(state.store, key, source, condition)
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
        Logger.warning("Rules: writing #{key}: #{ObjectStore.reason_message(reason)}")

        {{:error,
          {:unknown,
           "#{ObjectStore.reason_message(reason)}; #{key} may have been saved; list the rules to check"}},
         %{state | stale: true}}

      {:error, :precondition_failed} ->
        release(lock)
        {{:error, "#{key} changed concurrently; retry"}, state}

      {:error, reason} ->
        release(lock)
        {{:error, ObjectStore.reason_message(reason)}, state}
    end
  end

  defp release(lock) do
    case Lock.release(lock) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Rules: releasing the write lock: #{ObjectStore.reason_message(reason)}")
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

  # Adopt Publisher's new pool only on success; failure leaves the pool unchanged.
  defp activate(state, preparation) do
    case Publisher.activate(state.publisher, preparation) do
      {:ok, publisher, errors} -> {:ok, %{state | publisher: publisher}, errors}
      {:error, message, errors} -> {:error, message, errors}
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
      stack = Guardian.Failure.stacktrace(__STACKTRACE__)
      label = Guardian.Failure.reason_kind(reason)
      message = "Guardian.Rules.Server crashed: #{kind} #{label} (details redacted)"
      :erlang.raise(:error, %RuntimeError{message: message}, stack)
  end

  ## Logging

  defp schedule_poll do
    Process.send_after(self(), :poll, poll_ms())
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

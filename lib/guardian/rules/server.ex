defmodule Guardian.Rules.Server do
  @moduledoc """
  Loads, reloads, writes and publishes the rule set on this node.

  ## Startup

  `init/1` loads and validates every rule file before anything else in Guardian
  starts (it is `Guardian.Application`'s first child). A failed store call is retried
  with backoff (up to 10 s apart) for as long as it takes, whatever the failure, so
  Guardian is not up until the store answers; invalid settings refuse startup at once.
  A table whose stored rules fail validation is published as
  `{:invalid, message}`, so its events fail and other tables run normally.

  If this process restarts while Guardian runs, the published set (in
  `:persistent_term`) keeps serving and the store is re-read once in the background,
  so a store outage cannot take the rest of Guardian down.

  ## Reload

  `reload/0` re-reads the store, fetching only objects whose ETag changed. Writers call
  it on every connected node. Rules change only through writes, so nothing re-reads on
  a timer, and a failed reload is not retried: a node keeps its rules until its next
  reload or restart. Activation is the same as at startup: a table whose stored rules
  fail validation (or whose LOOKUP reads a counter of such a table) is published as
  invalid, with no last good rules kept. Nothing changes unless every changed table
  compiles and every changed table's module soft-purges; then the modules load and
  one map is published.

  ## Writes

  Under the store's write lock (a `Guardian.ObjectStore.Lock` on
  `lock_key/0`): read the whole set from the store,
  apply the change, reject it if it adds an error the stored set did not have
  (`Guardian.Rules.RuleSet.new_errors/2`), soft-purge the old code of the modules the
  write will load, here and on every connected node (up to 10 s), save the one file
  (conditional on the ETag read, or on absence), publish here, ask every connected
  node to reload (up to 10 s), then release. If any node still runs the old code of
  one of those modules, the write fails before the save with "rules changed too
  recently; try again", having changed nothing on any node. A failed save releases
  the lock too, and says the file may have been saved; if it was, the next reload
  finds its ETag changed and activates it.

  The lock is tried once: if another writer holds it, or a lock left by an interrupted
  write has not yet expired (the 120 s lease), the write fails at once as `:busy`,
  having changed nothing. Whether to try again is the caller's choice.

  Outcomes: `{:ok, %{errors: remaining messages, unconfirmed: nodes}}`,
  `{:error, {:rejected, messages}}`, `{:error, :busy}`, or `{:error, message}`.

  ## Modules

  `Guardian.Rules.Publisher` owns activation and publication, synchronously inside
  this server's callbacks, and keeps no state: each table has one module, replaced in
  place (see its module documentation). A Server restart keeps the published map and
  the loaded modules.

  ## Status and crash reports

  Nothing is redacted: `:sys.get_status/1` and a crash report show the state and the
  last message, rule text included, and a callback that raises crashes as is.
  `write/3` turns a timed-out or missing server into an error.
  """

  use GenServer
  require Logger

  alias Guardian.ObjectStore
  alias Guardian.ObjectStore.Lock
  alias Guardian.Rules
  alias Guardian.Rules.Publisher
  alias Guardian.Rules.RuleSet

  @reload_timeout_ms 10_000
  @lock_key "_write.lock"
  @lock_lease_ms 120_000
  @may_be_saved "may have been saved; list the rules to check; if it was, it takes effect " <>
                  "at the latest at the next successful rule write"

  @doc false
  def lock_key do
    @lock_key
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Callers include MCP tool calls, which run in Anubis's per-request tasks.
  def write(table, name, source) do
    GenServer.call(__MODULE__, {:write, table, name, source}, 90_000)
  catch
    # Answers the writer needs: its outcome is unknown, or nothing happened.
    :exit, {:timeout, _} ->
      {:error, "the rule write timed out; it #{@may_be_saved}"}

    :exit, {:noproc, _} ->
      {:error, "the rule server is unavailable; retry"}
  end

  def reload do
    GenServer.call(__MODULE__, :reload, @reload_timeout_ms)
  end

  @doc false
  # A writer's pre-save check on this node (`Guardian.Rules.Publisher.purge_for/1`).
  # Through this server, so it runs after any reload still pending here: a reload a
  # previous writer stopped waiting for cannot load after the check passed.
  def purge_for(hashes) do
    GenServer.call(__MODULE__, {:purge_for, hashes}, @reload_timeout_ms)
  end

  @impl true
  def init(_opts) do
    case Guardian.Rules.Config.store() do
      {:ok, store} ->
        Rules.put_store(store)
        # `files` is the set last activated (also the fetch cache); `stale` means the
        # published rules may not match it, so the next reload activates whatever it
        # reads even if the ETags are unchanged.
        state = %{store: store, files: %{}, stale: false}

        case Rules.published() do
          nil -> boot(state)
          _published -> {:ok, restart(state)}
        end

      {:error, message} ->
        {:stop, {:rules_store, message}}
    end
  end

  defp boot(state) do
    case read_with_retry(state, 1_000) do
      {:ok, files} ->
        case Publisher.activate(prepare(sources(files))) do
          {:ok, _errors} ->
            table_count =
              Enum.count(Rules.published(), fn {_table, module} -> is_atom(module) end)

            Logger.info(
              "Rules: #{map_size(files)} files for #{table_count} tables " <>
                "from #{ObjectStore.describe(state.store)}"
            )

            {:ok, %{state | files: files}}

          {:error, message, _errors} ->
            {:stop, {:rules_compile, message}}
        end
    end
  end

  # Retries any store failure indefinitely: Guardian waits for its rules rather than
  # starting without them.
  defp read_with_retry(state, backoff) do
    case read_set(state) do
      {:ok, files} ->
        {:ok, files}

      {:error, message} ->
        Logger.warning("Rules: #{message}; retrying in #{backoff} ms")
        Process.sleep(backoff)
        read_with_retry(state, min(backoff * 2, 10_000))
    end
  end

  defp restart(state) do
    send(self(), :catch_up)
    %{state | stale: true}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case reload_state(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, message, state} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:purge_for, hashes}, _from, state) do
    {:reply, Publisher.purge_for(hashes), state}
  end

  def handle_call({:write, table, name, source}, _from, state) do
    {reply, state} = write_rule(state, table, name, source)
    {:reply, reply, state}
  end

  # One read, for any write missed while this process was down. If it fails, `stale`
  # stays set and the published rules keep serving until the next reload or write.
  @impl true
  def handle_info(:catch_up, state) do
    case reload_state(state) do
      {:ok, state} -> {:noreply, state}
      {:error, _message, state} -> {:noreply, state}
    end
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
        {:error, "rule files kept changing during the read"}

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
          case Publisher.activate(prepare(sources(files))) do
            {:ok, _errors} -> {:ok, %{state | files: files, stale: false}}
            {:error, message, _errors} -> {:error, message, state}
          end
        end

      {:error, message} ->
        {:error, message, state}
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

      true ->
        case Lock.acquire(state.store, lock_key(), "#{node()}", lease_ms: @lock_lease_ms) do
          {:ok, lock} ->
            locked_write(state, lock, key, source)

          {:error, :busy} ->
            {{:error, :busy}, state}

          {:error, message} ->
            {{:error, message}, state}
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

          not purge_everywhere(Publisher.hashes(validation)) ->
            release(lock)
            {{:error, Publisher.too_recent_message()}, state}

          true ->
            save(state, lock, key, source, files, validation)
        end

      {:error, message} ->
        release(lock)
        {{:error, message}, state}
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
        files =
          if source == :delete,
            do: Map.delete(files, key),
            else: Map.put(files, key, %{etag: etag, source: source})

        {state, local_error, errors} =
          case Publisher.activate(validation) do
            {:ok, errors} -> {%{state | files: files, stale: false}, nil, errors}
            {:error, message, errors} -> {%{state | stale: true}, message, errors}
          end

        unconfirmed = broadcast_reload()
        # Held until every node has reloaded or the wait ended, so the next writer's
        # check on a node comes after this write's reload there (it queues behind it
        # on that node's server).
        release(lock)
        unconfirmed = if local_error, do: [node() | unconfirmed], else: unconfirmed

        {{:ok, %{errors: Enum.map(errors, & &1.message), unconfirmed: unconfirmed}}, state}

      {:error, :precondition_failed} ->
        release(lock)
        {{:error, "#{key} changed concurrently; retry"}, state}

      {:error, message} ->
        release(lock)
        {{:error, "#{message}; #{key} #{@may_be_saved}"}, state}
    end
  end

  defp release(lock) do
    case Lock.release(lock) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Rules: releasing the write lock: #{inspect(reason)}")
    end
  end

  # Asks every other connected node to reload; returns the nodes that did not confirm.
  # Sent straight to each node's server (no intermediate process, unlike :erpc), so a
  # reload this writer stopped waiting for is already queued there before the next
  # writer's check arrives.
  defp broadcast_reload do
    {replies, bad_nodes} =
      GenServer.multi_call(Node.list(), __MODULE__, :reload, @reload_timeout_ms)

    failed = for {node, reply} <- replies, reply != :ok, do: node
    bad_nodes ++ failed
  end

  # Before a save, each node soft-purges the old code of the modules it would load
  # for the new set, so a node still running old code refuses the write before
  # anything changes anywhere. Only the lock holder calls other nodes' servers, and a
  # reload calls none, so no two servers wait on each other. A node that does not
  # answer (unreachable, slow, still busy with an earlier reload, or an older build
  # mid-deploy) is not waited on: its own pre-load purge still protects it, and if
  # that fails it is named as unconfirmed, like any missed reload.
  defp purge_everywhere(hashes) do
    Publisher.purge_for(hashes) and
      Node.list()
      |> :erpc.multicall(__MODULE__, :purge_for, [hashes], @reload_timeout_ms)
      |> Enum.all?(&(&1 != {:ok, false}))
  end
end

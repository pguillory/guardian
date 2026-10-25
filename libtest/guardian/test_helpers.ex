defmodule Guardian.TestHelpers do
  @moduledoc """
  SQL, polling, process-finding, time-limit and segment helpers (picking, appending,
  intercepting appends) shared by tests. Import it in a test module.
  """

  import ExUnit.Assertions

  @doc """
  Resolves SQL text that holds exactly one executable statement and returns that
  statement (MatchError otherwise). Use it to resolve before injecting a fault:
  resolution reads schemas from every node.
  """
  def resolve_sql(sql) do
    [{statement, _labels}] = Guardian.Query.Resolver.resolve(sql)
    statement
  end

  @doc """
  Resolves and runs SQL text that holds exactly one executable statement and returns
  its rows. Unlike `Guardian.Query.execute/2`, a `Guardian.Query.Error` raises.
  """
  def run_sql(sql) do
    Guardian.Query.run(resolve_sql(sql))
  end

  @doc """
  Calls `fun` every 10 ms until it returns a truthy value, and fails the test if none
  does within `timeout_ms`. Returns `:ok`. `fun` must return a boolean-like value:
  an empty list is truthy here, so poll for a list with an explicit predicate.
  """
  def eventually(fun, timeout_ms \\ 5_000) do
    poll(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never held")

      true ->
        Process.sleep(10)
        poll(fun, deadline)
    end
  end

  @doc """
  Like `eventually/2` for a condition that waits on garbage collection, such as a
  released NIF resource: before each check it collects garbage in every process. It
  checks 51 times, 20 ms apart, and fails the test if the condition never holds.
  """
  def eventually_after_gc(fun) do
    poll_after_gc(fun, 50)
  end

  defp poll_after_gc(fun, attempts) do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)

    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(20)
        poll_after_gc(fun, attempts - 1)
    end
  end

  @doc """
  Waits until a call is queued at `pid`, a process the test has suspended, and
  fails the test if none arrives. Options:
  - `:node`, where `pid` runs (default: this node); a remote one is read over
    `:erpc`.
  - `:call`, a call message to wait for (`{:"$gen_call", _, call}`). Without it any
    queued message counts.

  Without `:call` it checks the queue length, then retries 500 times 10 ms apart;
  with it, it polls through `eventually/1` (10 ms, 5 s).
  """
  def await_queued_call(pid, opts \\ []) do
    node = Keyword.get(opts, :node, node())

    case Keyword.fetch(opts, :call) do
      {:ok, call} ->
        eventually(fn ->
          {:messages, messages} = process_info(node, pid, :messages)
          Enum.any?(messages, &match?({:"$gen_call", _, ^call}, &1))
        end)

      :error ->
        await_queue(node, pid, 500)
    end
  end

  defp await_queue(node, pid, attempts) do
    case process_info(node, pid, :message_queue_len) do
      {:message_queue_len, n} when n > 0 ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        await_queue(node, pid, attempts - 1)

      _ ->
        flunk("no call queued at the segment")
    end
  end

  @doc """
  The processes on `node` whose current stack runs code from any of `modules`, such
  as a query's pipeline workers
  (`[Guardian.Query.DistributedStream, Guardian.Query, Guardian.Query.Executor]`).
  """
  def processes_running(modules, node \\ node()) do
    processes_where(node, fn stack -> Enum.any?(modules, &(&1 in stack)) end)
  end

  @doc """
  The processes on `node` whose current stack runs code from every one of `modules`,
  such as a query worker blocked reading a segment
  (`[Guardian.Query.Executor, Guardian.Storage.Segment]`).
  """
  def processes_running_all(modules, node \\ node()) do
    processes_where(node, fn stack -> Enum.all?(modules, &(&1 in stack)) end)
  end

  defp processes_where(node, predicate) do
    node
    |> process_list()
    |> Enum.filter(fn pid ->
      case process_info(node, pid, :current_stacktrace) do
        {:current_stacktrace, frames} ->
          predicate.(Enum.map(frames, &elem(&1, 0)))

        nil ->
          false
      end
    end)
  end

  # Read locally without :erpc, so polls on this node keep the cadence of a plain
  # Process call.
  defp process_list(node) when node == node() do
    Process.list()
  end

  defp process_list(node) do
    :erpc.call(node, Process, :list, [])
  end

  defp process_info(node, pid, item) when node == node() do
    Process.info(pid, item)
  end

  defp process_info(node, pid, item) do
    :erpc.call(node, Process, :info, [pid, item])
  end

  @doc """
  Waits up to `timeout_ms` until no process on `node` but those in `except` runs code
  from `modules`, and fails the test naming the ones still alive.
  """
  def await_no_processes_running(modules, opts \\ []) do
    node = Keyword.get(opts, :node, node())
    except = Keyword.get(opts, :except, [])
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 5_000)
    await_none(modules, node, except, deadline)
  end

  defp await_none(modules, node, except, deadline) do
    case processes_running(modules, node) -- except do
      [] ->
        :ok

      pids ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("processes still running #{inspect(modules)} on #{node}: #{inspect(pids)}")
        else
          Process.sleep(20)
          await_none(modules, node, except, deadline)
        end
    end
  end

  @doc """
  The ID and process of `table`'s full segment at `index` (by ID order), as queries
  find it: written and loaded. Until its file is loaded, a full segment also has an
  in-memory process, and LoadedSegments' periodic scan can load the file at any
  moment, after which queries read the loaded copy (lookups check it first). A test
  that suspends or kills the in-memory process would then find queries unaffected.
  Fails if the segment is never written, as for a mutable segment.
  """
  @spec loaded_segment(String.t(), non_neg_integer()) :: {String.t(), pid()}
  def loaded_segment(table, index) do
    id = table |> Guardian.Storage.segment_ids() |> Enum.sort() |> Enum.at(index)
    filename = Guardian.Storage.SegmentFile.filename(table, id)
    :ok = Guardian.Storage.PersistedSegments.ping()
    eventually(fn -> File.exists?(filename) end, 30_000)
    # Loads just this file, with no call timeout (a full rescan is a 5 s call).
    :ok = Guardian.Storage.LoadedSegments.ensure_loaded(table, id)
    {:ok, pid} = Guardian.Storage.LoadedSegments.get_segment(id)
    {:ok, ^pid} = Guardian.Storage.get_segment(id)
    {id, pid}
  end

  @doc """
  Appends a row that may be nested to `segment`, flattening it first as
  `Guardian.Storage.append/2` does (`Guardian.Storage.Segment.append/2` takes flat rows).
  """
  def segment_append(segment, row) do
    Guardian.Storage.Segment.append(
      segment,
      Guardian.Storage.Flattening.flatten_event(Map.new(row))
    )
  end

  @doc """
  Writes a segment file holding flat `rows` to `filename`, through a temporary
  in-memory segment (appended, packed, stored, stopped), and returns `filename`. The
  caller removes the file.
  """
  def write_segment_file(filename, rows) do
    {:ok, segment} = Guardian.Storage.Segment.start_link()
    Enum.each(rows, &(:ok = Guardian.Storage.Segment.append(segment, &1)))
    :ok = Guardian.Storage.Segment.pack(segment)
    :ok = Guardian.Storage.Segment.store(segment, filename)
    GenServer.stop(segment)
    filename
  end

  @doc """
  Registers a one-call fake mutable segment for `table`, so the next append to it goes
  through the real Storage and GenServer path to `callback.(from, row)`, which replies
  (or fails) as the test needs. The fake unregisters itself before calling back, so
  later rows use real segments. Call it from the test process: cleanup is `on_exit`.
  It writes MutableSegments' registry directly, which test code may do to inject
  faults (`lib/guardian/storage/CLAUDE.md`).
  """
  def intercept_append(table, callback) do
    segment_id = Guardian.SegmentID.generate()

    segment =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:append, row}} ->
            # Unregister without stopping: deletion would stop this fake segment.
            :sys.replace_state(Guardian.Storage.MutableSegments, fn state ->
              true = :ets.delete(Guardian.Storage.MutableSegments, segment_id)
              state
            end)

            callback.(from, row)
        end
      end)

    :sys.replace_state(Guardian.Storage.MutableSegments, fn state ->
      true = :ets.insert(Guardian.Storage.MutableSegments, {segment_id, segment, table})
      state
    end)

    ExUnit.Callbacks.on_exit(fn ->
      # Kill first: deletion stops the segment, and this fake one does not answer.
      Process.exit(segment, :kill)
      Guardian.Storage.MutableSegments.delete_segment(segment_id)
    end)
  end

  @doc """
  Runs `fun` with the query time limit (`:query_time_limit_ms`) set to `ms`, then
  restores the previous setting, or removes it if there was none.
  """
  def with_time_limit(ms, fun) do
    previous = Application.fetch_env(:guardian, :query_time_limit_ms)
    Application.put_env(:guardian, :query_time_limit_ms, ms)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:guardian, :query_time_limit_ms, value)
        :error -> Application.delete_env(:guardian, :query_time_limit_ms)
      end
    end
  end
end

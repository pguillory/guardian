defmodule Guardian.Query do
  @moduledoc """
  SQL-like query engine for Guardian's event storage.

  Executes queries across distributed segments using columnar evaluation for
  performance. Supports SELECT, WHERE, GROUP BY, ORDER BY, and LIMIT operations.

  ## Query Execution Flow

  1. Resolve SQL text to SELECT statements (`Guardian.Query.Resolver.resolve/1`, called by
     `execute/2`)
  2. Generate query plan (`Planner.query_plan/1`, called by `Guardian.Query.Executor`)
  3. Execute plan steps using `Guardian.Query.DistributedStream` (`Guardian.Query.Executor`, in a query
     process `run/1` starts)
  4. Evaluate expressions columnwise per segment
  5. Return lazy stream of results

  ## Example Usage

      iex> Guardian.Query.execute("SELECT ip, count() FROM requests WHERE status = 404 GROUP BY ip")
      {:ok, ["ip", "count()"], [["1.2.3.4", 5], ["5.6.7.8", 3]]}

  `execute/2` is the entry point for SQL text: it is what the JSON and MCP query
  interfaces run; operators can call it from IEx too. `run/1` runs one already-resolved SELECT.

  ## Supported Operations

  - **SELECT** - Project columns and expressions
  - **FROM** - Scan table segments (distributed across cluster)
  - **WHERE** - Filter rows (evaluated per-segment)
  - **GROUP BY** - Aggregate with functions (count, sum, avg, min, max, etc.)
  - **ORDER BY** - Sort results (ASC/DESC)
  - **LIMIT** - Limit number of results

  ## Performance Characteristics

  - Full table scans are common and optimized
  - Columnar evaluation for cache efficiency
  - Distributed execution across cluster nodes
  - Lazy streaming (no intermediate materialization)
  - No indexes (queries are exploratory, not repetitive)

  See `test/guardian/query_test.exs` for query examples and `ARCHITECTURE.md` for details.
  """

  alias Guardian.Query.Executor
  alias Guardian.Query.Failure
  alias Guardian.Query.Limits
  alias Guardian.Query.WorkerErrors

  alias Guardian.AST.Node.Statements.SelectStatement

  @doc """
  Runs SQL text the way the query interfaces do: resolves it with
  `Guardian.Query.Resolver.resolve/1` (so SELECT *, SHOW TABLES, DESC and LET work), requires
  exactly one statement after LET statements, and runs it.

  Returns `{:ok, labels, rows}`, with the column labels taken from the statement
  before LET substitution (column names in their stored spelling). Returns
  `{:error, message}` for a failure of the query itself: zero or several statements,
  or a `Guardian.Query.Error` from `run/1` (a resource limit, a regular expression over its
  backtracking limit). Only running is covered by that rescue; anything raised while resolving (an
  `Guardian.AST.ParseError`, an ambiguous column, a failed schema lookup) propagates.

  Options:
  - `:on_parse_error`, a one-argument function called with the `Guardian.AST.ParseError` before
    it is reraised unchanged with its stacktrace. It must not raise: its exception
    would replace the parse error.
  """
  @spec execute(String.t(), keyword()) ::
          {:ok, [String.t()], [list()]} | {:error, String.t()}
  def execute(sql, opts \\ []) when is_binary(sql) do
    case resolve(sql, Keyword.get(opts, :on_parse_error, fn _error -> :ok end)) do
      [{statement, labels}] ->
        try do
          run(statement)
        rescue
          error in Guardian.Query.Error -> {:error, Exception.message(error)}
        else
          rows -> {:ok, labels, rows}
        end

      [] ->
        {:error, "Query resolved to no executable statements"}

      [_ | _] ->
        {:error, "Only single-statement queries are supported"}
    end
  end

  defp resolve(sql, on_parse_error) when is_function(on_parse_error, 1) do
    Guardian.Query.Resolver.resolve(sql)
  rescue
    error in Guardian.AST.ParseError ->
      stacktrace = __STACKTRACE__
      on_parse_error.(error)
      reraise error, stacktrace
  end

  @doc """
  Runs a SELECT and returns its rows.

  The query runs in its own process, the consumer of its DistributedStream pipeline.
  It may run for at most `Guardian.Query.Limits.time_limit_ms/0`; then it is stopped on every
  machine and this raises `Guardian.Query.Error`.
  Any failure inside distributed execution (a worker that raises or dies, a lost
  machine) stops the whole pipeline and fails this query with a `Guardian.Query.Error`; it
  never returns partial rows and never takes the caller down. Callers include the MCP
  server's shared process. The query process stops if the caller dies.

  Exceptions raised while workers evaluate expressions are collected by
  `Guardian.Query.WorkerErrors` and raised here as `Guardian.Query.Error`. `Guardian.Query.Executor` runs the
  plan's steps; `Guardian.Query.Failure` builds the bounded `Guardian.Query.Error`s for worker exceptions,
  pipeline exits and a query process that goes down.
  """
  def run(%SelectStatement{} = statement) do
    caller = self()
    tag = make_ref()
    limit_ms = Limits.time_limit_ms()
    {pid, ref} = spawn_monitor(fn -> run_in_query_process(statement, caller, tag) end)

    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])

        case result do
          {:ok, rows} -> rows
          {:error, exception, stacktrace} -> reraise exception, stacktrace
        end

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise Failure.query_process_down(reason)
    after
      limit_ms -> stop_timed_out_query(pid, ref, tag, limit_ms)
    end
  end

  defp stop_timed_out_query(pid, ref, tag, limit_ms) do
    # The kill reaches every router through its link, and each router's exit stops its
    # workers, on every machine.
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    # A result sent just before the kill would otherwise stay in the caller's mailbox
    # (for MCP, Anubis's long-lived server process).
    receive do
      {^tag, _result} -> :ok
    after
      0 -> :ok
    end

    raise Guardian.Query.Error, message: Limits.time_limit_message(limit_ms)
  end

  defp run_in_query_process(statement, caller, tag) do
    Limits.limit_heap()

    # Pipeline failures arrive as EXIT messages, which DistributedStream's consumer
    # turns into an exit caught below.
    Process.flag(:trap_exit, true)
    watch_caller(caller, self())
    errors = WorkerErrors.start()

    result =
      try do
        rows = Executor.run(statement, errors)

        case WorkerErrors.first(errors) do
          nil -> {:ok, rows}
          error -> {:error, error, []}
        end
      catch
        :error, reason ->
          {:error, Exception.normalize(:error, reason, __STACKTRACE__), __STACKTRACE__}

        :exit, reason ->
          {:error, Failure.from_exit(reason), []}

        kind, reason ->
          {:error, Failure.caught(kind, reason, __STACKTRACE__), []}
      end

    send(caller, {tag, result})

    # Not :normal, so linked helpers (the error collector, any pipeline process still
    # stopping) exit too.
    exit(:shutdown)
  end

  # Kills the query process (and through its links every pipeline process) if the
  # caller dies, whatever the query is doing, and exits normally once the query
  # process is gone, so no watcher outlives its query.
  defp watch_caller(caller, query_process) do
    spawn_link(fn ->
      caller_monitor = Process.monitor(caller)
      query_monitor = Process.monitor(query_process)

      receive do
        {:DOWN, ^caller_monitor, _, _, _reason} -> Process.exit(query_process, :kill)
        {:DOWN, ^query_monitor, _, _, _} -> :ok
      end
    end)
  end
end

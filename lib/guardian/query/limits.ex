defmodule Guardian.Query.Limits do
  @moduledoc """
  Per-query bounds that keep a careless query from exhausting a machine's memory.

  - Result size: a query returns at most 10,000 rows (`max_result_rows/0`). A `LIMIT`
    above that is a parse error, and a query without `LIMIT` is planned as if it had
    `LIMIT 10000` (`Guardian.Query.Planner`), so a bigger result is cut to 10,000
    rows without notice. Only returned rows count: rows scanned or aggregated don't,
    so aggregates over big tables read everything. Nothing counts result bytes: the
    heap limit below stops a result of many small values, but not one of large
    strings, which are shared binaries it doesn't count (spec section 12).
  - Strings that functions build are cut to 64 KiB (`Guardian.Query.Text`), never refused.
  - Time: a query may run for at most `:query_time_limit_ms` (30 s). `Guardian.Query.run/1`
    then stops it on every machine and raises. Nothing else bounds a query's running
    time: query stages and segment reads wait as long as they need to.
  - Heap: each process a query runs in (the query process and every
    `Guardian.Query.DistributedStream` worker, on every machine) is killed if its own Erlang
    heap grows past 256 MiB. The query then fails with a message saying a process
    was killed and may have exceeded its heap limit (an exit reason of `:killed` does
    not prove which limit was hit). The limit is not an operator setting; the test
    environment sets it to 16 MiB in `config/config.exs` through the
    `:query_max_heap_mb` application env, read on the machine the process runs on.

    `replace` on a value over 16 KiB runs in its own helper process with the same cap,
    so a value's match offsets stay bounded; a helper killed by it gives null for that
    value (`Guardian.Query.Regex.replace/3`).

  Exceeding the time or heap limit raises `Guardian.Query.Error` with what to change.
  These cover the common accidental cases, not total query memory: the heap limit is per process and checked
  at garbage collection, so it can overshoot, and it does not count GROUP BY state
  (ETS), column data (native memory), or shared binaries. A deliberate or exotic query
  can still exhaust a machine's memory.
  """

  @doc """
  The most rows a query returns: the largest `LIMIT` allowed, and the implicit one.
  """
  def max_result_rows do
    10_000
  end

  @doc """
  The per-process heap limit in MiB: 256, or the test environment's `:query_max_heap_mb`.
  """
  def max_heap_mb do
    Application.get_env(:guardian, :query_max_heap_mb, 256)
  end

  @doc """
  Puts this node's heap limit on the calling process: the first thing every query
  process and pipeline worker does. Shared binaries are not counted: a worker holds
  references to whole mapped segment files, which would be counted again in every
  process.
  """
  def limit_heap do
    words = div(max_heap_mb() * 1024 * 1024, :erlang.system_info(:wordsize))

    Process.flag(:max_heap_size, %{
      size: words,
      kill: true,
      # An over-limit query is the caller's outcome, answered with the heap message,
      # not a fault to log (CONTRIBUTING.md, "Logging").
      error_logger: false,
      include_shared_binaries: false,
    })

    :ok
  end

  @doc false
  def heap_kill_message do
    "a query process was killed; it may have exceeded its #{max_heap_mb()} MiB heap " <>
      "limit; narrow the query with WHERE, LIMIT or fewer groups"
  end

  def time_limit_ms do
    Application.get_env(:guardian, :query_time_limit_ms, 30_000)
  end

  @doc false
  def time_limit_message(limit_ms) do
    duration =
      cond do
        rem(limit_ms, 1000) == 0 and limit_ms > 1000 -> "#{div(limit_ms, 1000)} seconds"
        limit_ms == 1000 -> "1 second"
        true -> "#{limit_ms} ms"
      end

    "query exceeded its time limit of #{duration}; narrow it with WHERE or LIMIT"
  end
end

defmodule Guardian.Query.Limits do
  @moduledoc """
  Per-query bounds that keep a careless query from exhausting a machine's memory.

  - Result size: a query may return at most `:query_max_result_rows` rows (100,000)
    and about `:query_max_result_bytes` (64 MiB, by `:erlang.external_size/1` per
    row). It is counted where rows collect on the machine running the query: the
    final result, the input of an ORDER BY without LIMIT (sorted in memory), and the
    merge of an ORDER BY ... LIMIT. Rows scanned or aggregated are not counted, so
    aggregates over big tables are unaffected. ORDER BY with a LIMIT above the row cap
    is refused up front, since each machine would hold that many rows.
  - Strings that functions build are cut to 64 KiB (`Guardian.Query.Text`), never refused.
  - Time: a query may run for at most `:query_time_limit_ms` (30 s). `Guardian.Query.run/1`
    then stops it on every machine and raises. Nothing else bounds a query's running
    time: query stages and segment reads wait as long as they need to.
  - Heap: each process a query runs in (the query process and every
    `Guardian.Query.DistributedStream` worker, on every machine) is killed if its own Erlang
    heap grows past `:query_max_heap_mb` (256 MiB; 0 turns it off), read on the
    machine the process runs on. The query then fails with a message saying a process
    was killed and may have exceeded its heap limit (an exit reason of `:killed` does
    not prove which limit was hit).

    `replace` on a value over 16 KiB runs in its own helper process with the same cap
    (256 MiB when the limit is off), so a value's match offsets stay bounded even with
    the limit off; a helper killed by it gives null for that value
    (`Guardian.Query.Regex.replace/3`).

  Exceeding a bound raises `Guardian.Query.Error` with what to change. These cover the common
  accidental cases, not total query memory: the heap limit is per process and checked
  at garbage collection, so it can overshoot, and it does not count GROUP BY state
  (ETS), column data (native memory), or shared binaries. A deliberate or exotic query
  can still exhaust a machine's memory.
  """

  def max_result_rows do
    Application.get_env(:guardian, :query_max_result_rows, 100_000)
  end

  def max_result_bytes do
    Application.get_env(:guardian, :query_max_result_bytes, 64 * 1024 * 1024)
  end

  @doc """
  The per-process heap limit in MiB (`:query_max_heap_mb`), or 0 when it is off.
  """
  def max_heap_mb do
    Application.get_env(:guardian, :query_max_heap_mb, 256)
  end

  @doc """
  Puts this node's heap limit on the calling process: the first thing every query
  process and pipeline worker does. With the limit off, the process is left alone.
  Shared binaries are not counted: a worker holds references to whole mapped
  segment files, which would be counted again in every process.
  """
  def limit_heap do
    case max_heap_mb() do
      mb when is_integer(mb) and mb > 0 ->
        words = div(mb * 1024 * 1024, :erlang.system_info(:wordsize))

        Process.flag(:max_heap_size, %{
          size: words,
          kill: true,
          error_logger: true,
          include_shared_binaries: false,
        })

        :ok

      _ ->
        :ok
    end
  end

  @doc false
  def heap_kill_message do
    "a query process was killed; it may have exceeded its heap limit " <>
      "(GUARDIAN_QUERY_MAX_HEAP_MB); narrow the query with WHERE, LIMIT or fewer groups"
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

  @doc """
  Passes rows through, raising once more than the result cap has gone by.
  """
  def cap_rows(stream) do
    max_rows = max_result_rows()
    max_bytes = max_result_bytes()

    Stream.transform(stream, {0, 0}, fn row, {rows, bytes} ->
      rows = rows + 1
      bytes = bytes + :erlang.external_size(row)

      cond do
        rows > max_rows ->
          raise Guardian.Query.Error,
            message:
              "query result exceeds #{max_rows} rows; add a LIMIT, narrow it with WHERE, " <>
                "or aggregate with GROUP BY"

        bytes > max_bytes ->
          raise Guardian.Query.Error,
            message:
              "query result exceeds #{div(max_bytes, 1024 * 1024)} MiB; add a LIMIT, " <>
                "select fewer or smaller columns, or aggregate with GROUP BY"

        true ->
          {[row], {rows, bytes}}
      end
    end)
  end

  @doc """
  Refuses an ORDER BY ... LIMIT whose limit exceeds the result cap.
  """
  def check_sorted_limit!(limit) do
    max_rows = max_result_rows()

    if limit > max_rows do
      raise Guardian.Query.Error,
        message:
          "ORDER BY with LIMIT #{limit} exceeds the #{max_rows}-row result cap; lower the LIMIT"
    end

    :ok
  end
end

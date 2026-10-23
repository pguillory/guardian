defmodule Web.Query do
  @moduledoc """
  Runs SQL for the JSON `/query` endpoint and the MCP `query` tool, as `Web.Ingest`
  does ingestion for both. Don't resolve or run queries in Web any other way.

  It calls `Query.execute/2` and records every query, whatever its outcome, with
  `Web.QueryLog.record/4` (the `queries` table). It also hands any `AST.ParseError` to
  `Web.QueryParseErrors.record/4`, which records a `query_parse_errors` row. Results
  are returned and raised errors reraised unchanged with their stacktrace, so the
  caller's response is exactly what it would have been.
  """

  @doc """
  Runs `sql` with `Query.execute/2` and returns its result. `caller_fun` returns the
  caller fields of a recorded row (`Web.QueryParseErrors.http_caller/1` or
  `mcp_caller/1`). Options: `:server` names the parse-error recorder, `:query_log`
  the query recorder, and `:execute` replaces `Query.execute/2` (for tests).
  """
  @spec execute(String.t(), (-> map()), keyword()) ::
          {:ok, [String.t()], [list()]} | {:error, String.t()}
  def execute(sql, caller_fun, opts \\ []) do
    timestamp = Timestamp.now()
    start = System.monotonic_time()
    log = &record(sql, &1, timestamp, start, caller_fun, opts)

    # Reads only `:server`.
    on_parse_error = &Web.QueryParseErrors.record(sql, &1, caller_fun, opts)

    execute = Keyword.get(opts, :execute, &Query.execute/2)

    try do
      execute.(sql, on_parse_error: on_parse_error)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        log.(failure(kind, reason, stacktrace))
        :erlang.raise(kind, reason, stacktrace)
    else
      {:ok, _labels, rows} = result ->
        log.({:ok, length(rows)})
        result

      {:error, message} = result ->
        log.({:error, "query", message})
        result
    end
  end

  defp record(sql, outcome, timestamp, start, caller_fun, opts) do
    info = %{
      timestamp: timestamp,
      duration_native: System.monotonic_time() - start,
      caller_fun: caller_fun,
    }

    Web.QueryLog.record(sql, outcome, info, server: Keyword.get(opts, :query_log, Web.QueryLog))
  end

  # The outcome of a query that raised, exited or threw. An exception's message may
  # carry query text or data; that is what the table records, as the MCP caller sees
  # it. An exit or throw is named by kind only. Never raises: it runs while the
  # original error is being reraised.
  defp failure(kind, reason, stacktrace) do
    describe_failure(kind, reason, stacktrace)
  catch
    _kind, _reason -> {:error, "internal", nil}
  end

  defp describe_failure(:error, %AST.ParseError{} = error, _stacktrace) do
    {:error, "parse", safe_message(error)}
  end

  defp describe_failure(:error, reason, stacktrace) do
    {:error, "internal", safe_message(Exception.normalize(:error, reason, stacktrace))}
  end

  defp describe_failure(kind, reason, stacktrace) do
    {:error, "internal", Engine.failure_kind(kind, reason, stacktrace)}
  end

  # `Exception.message/1` can itself raise (a broken `message/1`); the outcome is still
  # recorded, with the exception's module.
  defp safe_message(exception) do
    Exception.message(exception)
  rescue
    _ -> inspect(exception.__struct__)
  end
end

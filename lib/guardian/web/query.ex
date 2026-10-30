defmodule Guardian.Web.Query do
  @moduledoc """
  Runs SQL for the MCP `query` tool, Guardian's one query interface. Don't resolve or
  run queries in Web any other way.

  It calls `Guardian.Query.execute/1` and records every query, whatever its outcome, with
  `Guardian.Web.QueryLog.record/4` (the `queries` table). A parse error also goes to
  `Guardian.Web.QueryParseErrors.record/5`, which records a `query_parse_errors` row, and
  comes back as `{:error, message}`. Raised errors are reraised unchanged.
  """

  alias Guardian.AST.ParseError
  alias Guardian.Web.QueryParseErrors

  # Internal compile-time test seam, not an operator setting. Releases call
  # `Guardian.Query` directly.
  @query_backend Application.compile_env(:guardian, [__MODULE__, :query_backend], Guardian.Query)

  @doc """
  Runs `sql` with `Guardian.Query.execute/1` and returns its result. `caller_fun` returns the
  caller fields of a recorded row
  (`Guardian.Web.QueryParseErrors.mcp_caller/1`). Options: `:server` names the parse-error recorder and `:query_log`
  the query recorder.
  """
  @spec execute(String.t(), (-> map()), keyword()) ::
          {:ok, [String.t()], [list()]} | {:error, String.t()}
  def execute(sql, caller_fun, opts \\ []) do
    timestamp = Guardian.Timestamp.now()
    start = System.monotonic_time()
    log = &record(sql, &1, timestamp, start, caller_fun, opts)

    try do
      @query_backend.execute(sql)
    catch
      # Every query is recorded, whatever its outcome (spec section 8).
      kind, reason ->
        stacktrace = __STACKTRACE__
        log.(failure(kind, reason, stacktrace))
        :erlang.raise(kind, reason, stacktrace)
    else
      {:ok, _labels, rows} = result ->
        log.({:ok, length(rows)})
        result

      {:error, %ParseError{} = error} ->
        message = ParseError.message(error)
        QueryParseErrors.record(sql, error, caller_fun, System.system_time(:second), opts)
        log.({:error, "parse", message})
        {:error, message}

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

    Guardian.Web.QueryLog.record(sql, outcome, info,
      server: Keyword.get(opts, :query_log, Guardian.Web.QueryLog)
    )
  end

  # The outcome of a query that raised, exited or threw. An exception's message may
  # carry query text or data; that is what the table records. An exit or throw is named
  # by kind only.
  defp failure(:error, reason, stacktrace) do
    {:error, "internal", Exception.message(Exception.normalize(:error, reason, stacktrace))}
  end

  defp failure(kind, reason, stacktrace) do
    {:error, "internal", Guardian.Failure.kind(kind, reason, stacktrace)}
  end
end

defmodule Web.Query do
  @moduledoc """
  Runs SQL for the JSON `/query` endpoint and the MCP `query` tool, as `Web.Ingest`
  does ingestion for both. Don't resolve or run queries in Web any other way.

  It calls `Query.execute/2` and hands any `AST.ParseError` to
  `Web.QueryParseErrors.record/4`, which records a `query_parse_errors` row; the error
  is then reraised unchanged with its stacktrace, so the caller's response is exactly
  what it would have been.
  """

  @doc """
  Runs `sql` with `Query.execute/2` and returns its result. `caller_fun` returns the
  caller fields of a parse-error row (`Web.QueryParseErrors.http_caller/1` or
  `mcp_caller/1`); it runs only on a parse failure. Options: `:server` names the
  recorder.
  """
  @spec execute(String.t(), (-> map()), keyword()) ::
          {:ok, [String.t()], [list()]} | {:error, String.t()}
  def execute(sql, caller_fun, opts \\ []) do
    Query.execute(sql, on_parse_error: &Web.QueryParseErrors.record(sql, &1, caller_fun, opts))
  end
end

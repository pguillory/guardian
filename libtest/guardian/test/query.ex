defmodule Guardian.Test.Query do
  @moduledoc """
  Resolves and runs SQL for tests. Query helpers are as async-safe as the workload and
  shared state they use. `with_time_limit/2` changes node-wide application env, so it
  requires `async: false`.
  """

  @doc """
  Resolves SQL text that holds exactly one executable statement and returns that
  statement (MatchError otherwise). Use it to resolve before injecting a fault:
  resolving a `SELECT *` reads schemas from every node.
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
  Runs `fun` with the query time limit (`:query_time_limit_ms`) set to `ms`, then
  restores the previous setting, or removes it if there was none.
  """
  def with_time_limit(ms, fun) do
    Guardian.Test.Env.with_env([query_time_limit_ms: ms], fun)
  end
end

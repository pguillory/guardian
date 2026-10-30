defmodule Guardian.Test.Web.QueryBackend do
  @moduledoc false

  # The test build's `Guardian.Query` for `Guardian.Web.Query`: passes through, unless
  # the calling process asked for a failure. Exits and throws can't be provoked through
  # the real query path, which turns its failures into `Guardian.Query.Error`.

  @failure {__MODULE__, :failure}

  def execute(sql, opts) do
    case Process.delete(@failure) do
      nil -> Guardian.Query.execute(sql, opts)
      {kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  @doc """
  Makes this process's next `Guardian.Web.Query.execute/3` fail with exactly `kind`,
  `reason` and `stacktrace`.
  """
  def fail_next(kind, reason, stacktrace) do
    Process.put(@failure, {kind, reason, stacktrace})
    :ok
  end
end

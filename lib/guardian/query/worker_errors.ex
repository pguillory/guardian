defmodule Guardian.Query.WorkerErrors do
  @moduledoc """
  Carries exceptions from query workers back to the query.

  Expressions are evaluated inside DistributedStream workers on every node. A worker
  that crashes fails the whole query (DistributedStream links every worker), but a
  plain process that dies from an exception is logged with its reason, which can carry
  row values. Instead, the evaluation closures run under `guard/2`: the first
  exception in a worker is reported to a collector process for the query and
  acknowledged before the worker goes on, the worker skips its remaining work for that
  query (returning no rows, so nothing crashes and no crash report reaches the log),
  and the query raises the reported error once its stream has ended. The stream ends
  only after every worker has finished, and each report was acknowledged before its
  worker finished, so no report can be missed. The acknowledgement is waited for with
  no timeout (the query's time limit bounds it), and a collector that is gone when the
  query asks for its first error fails the query, so a lost report never reads as
  success. (A LIMIT that is satisfied early stops the stream before every worker
  finishes; errors in work the query no longer needs and that were not yet reported
  are then ignored.)

  Reports are reduced to a `Guardian.Query.Error` with a bounded message (`Guardian.Query.Failure.caught/3`)
  before they leave the worker, so they stay small on the wire and carry no raw terms.
  """

  @doc """
  Starts a collector linked to the calling process.
  """
  def start do
    spawn_link(fn -> collect(nil) end)
  end

  @doc """
  Runs `fun` in a worker and returns its result. If it raises, exits, or throws, the
  error is reported and `[]` is returned; later calls in the same process for the
  same collector return `[]` without running.
  """
  def guard(collector, fun) when is_pid(collector) and is_function(fun, 0) do
    if Process.get({__MODULE__, collector}) do
      []
    else
      try do
        fun.()
      catch
        # A relay: carries the worker's failure, with its message, to the whole query.
        kind, reason ->
          Process.put({__MODULE__, collector}, true)
          report(collector, Guardian.Query.Failure.caught(kind, reason, __STACKTRACE__))
          []
      end
    end
  end

  @doc """
  Returns the first reported error, or nil. A collector that is gone may have held an
  error, so it returns an error too.
  """
  def first(collector) when is_pid(collector) do
    ref = Process.monitor(collector)
    send(collector, {:first, self(), ref})

    receive do
      {^ref, error} ->
        Process.demonitor(ref, [:flush])
        error

      {:DOWN, ^ref, _, _, _} ->
        %Guardian.Query.Error{message: "query failed: its worker error collector stopped"}
    end
  end

  # No timeout: the collector acknowledges at once while it lives. A collector that is
  # gone is not this worker's failure to raise: either the query is already over (a
  # LIMIT that stopped early, or another failure), or first/1 fails it.
  defp report(collector, error) do
    ref = Process.monitor(collector)
    send(collector, {:report, self(), ref, error})

    receive do
      {^ref, :ok} -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  defp collect(first) do
    receive do
      {:report, from, ref, error} ->
        send(from, {ref, :ok})
        collect(first || error)

      {:first, from, ref} ->
        send(from, {ref, first})
        collect(first)
    end
  end
end

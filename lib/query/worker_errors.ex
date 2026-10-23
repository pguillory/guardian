defmodule Query.WorkerErrors do
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
  worker finished, so no report can be missed. (A LIMIT that is satisfied early stops
  the stream before every worker finishes; errors in work the query no longer needs
  are then ignored.)

  Reports are reduced to a `Query.Error` with a bounded message (`Query.Failure.caught/3`)
  before they leave the worker, so they stay small on the wire and carry no raw terms.
  """

  @ack_timeout 5_000

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
        kind, reason ->
          Process.put({__MODULE__, collector}, true)
          report(collector, Query.Failure.caught(kind, reason, __STACKTRACE__))
          []
      end
    end
  end

  @doc """
  Returns the first reported error, or nil.
  """
  def first(collector) when is_pid(collector) do
    ref = Process.monitor(collector)
    send(collector, {:first, self(), ref})

    receive do
      {^ref, error} ->
        Process.demonitor(ref, [:flush])
        error

      {:DOWN, ^ref, _, _, _} ->
        nil
    end
  end

  defp report(collector, error) do
    ref = Process.monitor(collector)
    send(collector, {:report, self(), ref, error})

    receive do
      {^ref, :ok} -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      @ack_timeout -> Process.demonitor(ref, [:flush])
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

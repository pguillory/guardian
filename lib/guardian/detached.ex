defmodule Guardian.Detached do
  @moduledoc """
  Runs work that must finish even if its caller is killed.

  `run/1` runs a function in a new process that is not linked to the caller, waits
  for it, and returns its result. If the caller dies while waiting, the function
  keeps running to the end. A raise, throw or exit inside the function is caught there
  and raised again in the caller with its original stacktrace, so the caller sees
  exactly what running the function itself would have produced and no crash report is
  written for the worker.

  The worker is not supervised: it does not outlive the VM, so a node shutdown can
  still stop it partway, and an error it raises after its caller died is not logged.
  """

  @doc """
  Runs `fun` in an unlinked process and returns its result, or raises what it raised.
  If the worker itself is killed from outside, the caller exits with its reason.
  """
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        reply =
          try do
            {:ok, fun.()}
          catch
            kind, reason -> {:raise, kind, reason, __STACKTRACE__}
          end

        send(caller, {ref, reply})
      end)

    receive do
      {^ref, reply} ->
        Process.demonitor(monitor, [:flush])
        unwrap(reply)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  defp unwrap({:ok, result}) do
    result
  end

  defp unwrap({:raise, kind, reason, stacktrace}) do
    :erlang.raise(kind, reason, stacktrace)
  end
end

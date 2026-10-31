defmodule Guardian.Test.Processes do
  @moduledoc """
  Observes process queues and stacks on this node or peers, for `:cluster` tests.
  Default-suite tests don't peek at processes (CONTRIBUTING.md, "Testing philosophy").
  """

  import ExUnit.Assertions

  @doc """
  Waits until a call is queued at `pid`, a process the test has suspended, and
  fails the test if none arrives. Options:
  - `:node`, where `pid` runs (default: this node); a remote one is read over
    `:erpc`.
  - `:call`, a call message to wait for (`{:"$gen_call", _, call}`). Without it any
    queued message counts.

  Without `:call` it checks the queue length, then retries 500 times 10 ms apart;
  with it, it polls through `Guardian.Test.Polling.eventually/1` (10 ms, 5 s).
  """
  def await_queued_call(pid, opts \\ []) do
    node = Keyword.get(opts, :node, node())

    case Keyword.fetch(opts, :call) do
      {:ok, call} ->
        Guardian.Test.Polling.eventually(fn ->
          {:messages, messages} = process_info(node, pid, :messages)
          Enum.any?(messages, &match?({:"$gen_call", _, ^call}, &1))
        end)

      :error ->
        await_queue(node, pid, 500)
    end
  end

  defp await_queue(node, pid, attempts) do
    case process_info(node, pid, :message_queue_len) do
      {:message_queue_len, n} when n > 0 ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        await_queue(node, pid, attempts - 1)

      _ ->
        flunk("no call queued at the segment")
    end
  end

  @doc """
  The processes on `node` whose current stack runs code from any of `modules`, such
  as a query's pipeline workers (`Guardian.Test.Query.query_modules/0`).
  """
  def processes_running(modules, node \\ node()) do
    processes_where(node, fn stack -> Enum.any?(modules, &(&1 in stack)) end)
  end

  defp processes_where(node, predicate) do
    node
    |> process_list()
    |> Enum.filter(fn pid ->
      case process_info(node, pid, :current_stacktrace) do
        {:current_stacktrace, frames} ->
          predicate.(Enum.map(frames, &elem(&1, 0)))

        nil ->
          false
      end
    end)
  end

  # Read locally without :erpc, so polls on this node keep the cadence of a plain
  # Process call.
  defp process_list(node) when node == node() do
    Process.list()
  end

  defp process_list(node) do
    :erpc.call(node, Process, :list, [])
  end

  defp process_info(node, pid, item) when node == node() do
    Process.info(pid, item)
  end

  defp process_info(node, pid, item) do
    :erpc.call(node, Process, :info, [pid, item])
  end
end

defmodule Guardian.Rules.Runner do
  @moduledoc """
  Runs a table's rules on a batch of flattened rows, outside the calling process.

  The rules run in a short-lived worker with this node's query heap limit
  (`Guardian.Query.Limits.max_heap_mb/0`, reported without the error_logger report: a
  heap kill is noise). It takes the rows in order and sends back each row's result as it
  finishes. Each row has `time_limit_ms/0` (1 s): if the worker exceeds it or its heap
  limit, that row fails and a new worker goes on with the next row. A worker that
  crashes any other way takes the batch with it: its exit reason becomes this process's
  exit, which is the caller's 500. Counter updates already made stay.

  The worker reads the table's compiled module once per row (`Guardian.Rules.lookup/1`), so a
  reload between rows applies to the rows after it; each row sees one rule set.
  Arrival coordinates come from Engine before validation, outside caller row data.
  Each event snapshots membership on entry to the worker.

  Outcomes: `{:ok, row}`, or `{:error, message}` for a row over a limit or with invalid
  rules, which must not be stored.
  """

  def time_limit_ms do
    Application.get_env(:guardian, :rules_time_limit_ms, 1_000)
  end

  @spec run(String.t(), [map()]) :: [{:ok, map()} | {:error, String.t()}]
  def run(_table, []) do
    []
  end

  def run(table, rows) do
    run_with_metadata(table, Enum.map(rows, &{&1, Guardian.Counters.Arrival.now()}))
  end

  @doc false
  def run_with_metadata(table, rows) do
    rows
    |> Enum.with_index()
    |> run_from(table, [])
    |> Enum.reverse()
  end

  defp run_from([], _table, acc) do
    acc
  end

  defp run_from(rows, table, acc) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        limit_heap()

        Enum.each(rows, fn {{row, arrival}, index} ->
          event = Guardian.Rules.Event.start(arrival)
          send(caller, {ref, index, apply_rules(table, row, event)})
        end)
      end)

    collect(rows, table, acc, ref, pid, monitor)
  end

  defp collect([], _table, acc, _ref, _pid, monitor) do
    Process.demonitor(monitor, [:flush])
    acc
  end

  defp collect([{_row, index} | rest], table, acc, ref, pid, monitor) do
    receive do
      {^ref, ^index, result} ->
        collect(rest, table, [result | acc], ref, pid, monitor)

      # The heap limit. The time limit below flushes this message, so it never lands here.
      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        flush(ref)
        run_from(rest, table, [over_limit(table) | acc])

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        exit(reason)
    after
      time_limit_ms() ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        flush(ref)
        run_from(rest, table, [over_limit(table) | acc])
    end
  end

  # Drops results a stopped worker sent after the caller stopped waiting for them.
  defp flush(ref) do
    receive do
      {^ref, _index, _result} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp over_limit(table) do
    {:error, "rules for #{table} exceeded their time or memory limit; the event was not stored"}
  end

  defp apply_rules(table, row, event) do
    case Guardian.Rules.lookup(table) do
      nil ->
        {:ok, row}

      {:invalid, message} ->
        {:error, "rules for #{table} are invalid (#{message}); the event was not stored"}

      module ->
        {:ok, module.apply(row, event)}
    end
  end

  defp limit_heap do
    Process.flag(:max_heap_size, %{
      size:
        div(Guardian.Query.Limits.max_heap_mb() * 1024 * 1024, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: false,
      include_shared_binaries: false,
    })
  end
end

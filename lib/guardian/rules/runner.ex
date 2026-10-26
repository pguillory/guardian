defmodule Guardian.Rules.Runner do
  @moduledoc """
  Runs a table's rules on a batch of flattened rows, outside the calling process.

  The rules run in a short-lived worker with this node's query heap limit
  (`Guardian.Query.Limits.max_heap_mb/0`, reported without the error_logger report, so no
  crash report carries an event's values). It takes the rows in order and sends back
  each row's result as it finishes. Each row has `time_limit_ms/0` (1 s): if the
  worker exceeds it or its heap limit, or dies, that row fails and a new worker goes on
  with the next row. So every row gets its own outcome, in order.

  The worker reads the table's compiled module once per row (`Guardian.Rules.lookup/1`), so a
  reload between rows applies to the rows after it; each row sees one rule set.
  Arrival coordinates come from Engine before validation, outside caller row data.
  One failed-counter-wait budget lives outside replaceable workers; each event
  snapshots membership and starts its own counter phase on entry to the worker.

  Outcomes: `{:ok, row}`, or `{:error, message}` for a row that must not be stored.
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
    batch = Guardian.Counters.Client.new_batch()

    rows
    |> Enum.with_index()
    |> run_from(table, [], batch)
    |> Enum.reverse()
  end

  defp run_from([], _table, acc, _batch) do
    acc
  end

  defp run_from(rows, table, acc, batch) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        limit_heap()

        Enum.each(rows, fn {{row, arrival}, index} ->
          event = Guardian.Rules.Event.start(arrival, batch)
          send(caller, {ref, index, apply_rules(table, row, event)})
        end)
      end)

    collect(rows, table, acc, ref, pid, monitor, batch)
  end

  defp collect([], _table, acc, _ref, _pid, monitor, _batch) do
    Process.demonitor(monitor, [:flush])
    acc
  end

  defp collect([{_row, index} | rest], table, acc, ref, pid, monitor, batch) do
    receive do
      {^ref, ^index, result} ->
        collect(rest, table, [result | acc], ref, pid, monitor, batch)

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        flush(ref)
        run_from(rest, table, [over_limit(table, "worker exit") | acc], batch)
    after
      time_limit_ms() ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        flush(ref)
        run_from(rest, table, [over_limit(table, "time limit") | acc], batch)
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

  defp over_limit(table, kind) do
    Guardian.Rules.Runtime.note_failure("#{table}/", "-", kind)
    {:error, "rules for #{table} exceeded their time or memory limit; the event was not stored"}
  end

  defp apply_rules(table, row, event) do
    case Guardian.Rules.lookup(table) do
      nil ->
        {:ok, row}

      {:invalid, message} ->
        {:error, "rules for #{table} are invalid (#{message}); the event was not stored"}

      module ->
        try do
          {:ok, module.apply(row, event)}
        rescue
          e in Guardian.Rules.Runtime.Failure -> {:error, Exception.message(e)}
        catch
          # Anything else (Guardian.Rules.Runtime catches statement failures itself) is reported
          # by kind only: an uncaught raise here would put the row in a crash report.
          kind, reason ->
            failure_kind = Guardian.Failure.kind(kind, reason, __STACKTRACE__)
            Guardian.Rules.Runtime.note_failure("#{table}/", "-", failure_kind)
            {:error, "rules for #{table} failed (#{failure_kind}); the event was not stored"}
        end
    end
  end

  defp limit_heap do
    case Guardian.Query.Limits.max_heap_mb() do
      mb when is_integer(mb) and mb > 0 ->
        Process.flag(:max_heap_size, %{
          size: div(mb * 1024 * 1024, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: false,
        })

      _ ->
        :ok
    end
  end
end

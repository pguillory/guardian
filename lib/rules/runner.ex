defmodule Rules.Runner do
  @moduledoc """
  Runs a table's rules on a batch of flattened rows, outside the calling process.

  The rules run in a short-lived worker with this node's query heap limit
  (`Query.Limits.max_heap_mb/0`, reported without the error_logger report, so no
  crash report carries an event's values). It takes the rows in order and sends back
  each row's result as it finishes. Each row has `time_limit_ms/0` (1 s): if the
  worker exceeds it or its heap limit, or dies, that row fails and a new worker goes on
  with the next row. So every row gets its own outcome, in order.

  The worker reads the table's compiled module once per row (`Rules.lookup/1`), so a
  reload between rows applies to the rows after it; each row sees one rule set.

  Outcomes: `{:ok, row}`, or `{:error, message}` for a row that must not be stored. With
  `:guardian, :rules_on_failure` set to `:skip`, a row over its limits is passed on
  unchanged instead (see `Rules.Runtime`).
  """

  def time_limit_ms, do: Application.get_env(:guardian, :rules_time_limit_ms, 1_000)

  @spec run(String.t(), [map()]) :: [{:ok, map()} | {:error, String.t()}]
  def run(_table, []), do: []

  def run(table, rows) do
    rows
    |> Enum.with_index()
    |> run_from(table, [])
    |> Enum.reverse()
  end

  defp run_from([], _table, acc), do: acc

  defp run_from(rows, table, acc) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        limit_heap()

        Enum.each(rows, fn {row, index} -> send(caller, {ref, index, apply_rules(table, row)}) end)
      end)

    collect(rows, table, acc, ref, pid, monitor)
  end

  defp collect([], _table, acc, _ref, _pid, monitor) do
    Process.demonitor(monitor, [:flush])
    acc
  end

  defp collect([{row, index} | rest], table, acc, ref, pid, monitor) do
    receive do
      {^ref, ^index, result} ->
        collect(rest, table, [result | acc], ref, pid, monitor)

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        flush(ref)
        run_from(rest, table, [over_limit(table, row, "worker exit") | acc])
    after
      time_limit_ms() ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        flush(ref)
        run_from(rest, table, [over_limit(table, row, "time limit") | acc])
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

  defp over_limit(table, row, kind) do
    Rules.Runtime.note_failure("#{table}/", "-", kind)

    case Application.get_env(:guardian, :rules_on_failure, :reject) do
      :skip ->
        {:ok, row}

      :reject ->
        {:error,
         "rules for #{table} exceeded their time or memory limit; the event was not stored"}
    end
  end

  defp apply_rules(table, row) do
    case Rules.lookup(table) do
      nil ->
        {:ok, row}

      {:invalid, message} ->
        {:error, "rules for #{table} are invalid (#{message}); the event was not stored"}

      module ->
        try do
          {:ok, module.apply(row)}
        rescue
          e in Rules.Runtime.Failure -> {:error, Exception.message(e)}
        catch
          # Anything else (Rules.Runtime catches statement failures itself) is reported
          # by kind only: an uncaught raise here would put the row in a crash report.
          kind, reason ->
            failure_kind = Engine.failure_kind(kind, reason, __STACKTRACE__)
            Rules.Runtime.note_failure("#{table}/", "-", failure_kind)
            {:error, "rules for #{table} failed (#{failure_kind}); the event was not stored"}
        end
    end
  end

  defp limit_heap do
    case Query.Limits.max_heap_mb() do
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

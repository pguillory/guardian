defmodule Guardian.Rules.Runner do
  @moduledoc """
  Runs a table's rules on a batch of flattened rows, one row at a time, in the calling
  process. There is no per-row time or memory limit: a rule that raises fails the
  caller's request (CONTRIBUTING.md, "Exception handling"). Counter updates already
  made stay.

  Each row reads the table's compiled module (`Guardian.Rules.lookup/1`), so a reload
  between rows applies to the rows after it; each row sees one rule set. Arrival
  coordinates come from Engine before validation, outside caller row data. Each event
  snapshots counter membership when its rules start.

  Outcomes: `{:ok, row}`, or `{:error, message}` for a row whose table's rules are
  invalid, which must not be stored.
  """

  @spec run(String.t(), [map()]) :: [{:ok, map()} | {:error, String.t()}]
  def run(table, rows) do
    run_with_metadata(table, Enum.map(rows, &{&1, Guardian.Counters.Arrival.now()}))
  end

  @doc false
  def run_with_metadata(table, rows) do
    Enum.map(rows, fn {row, arrival} ->
      apply_rules(table, row, Guardian.Rules.Event.start(arrival))
    end)
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
end

defmodule Guardian.Rules.CounterDefinition do
  @moduledoc "Immutable counter metadata bound into TRACK and LOOKUP plans."
  @enforce_keys [:identity, :operator, :window_ms, :bucket_ms, :group_arity]
  defstruct [:identity, :operator, :window_ms, :bucket_ms, :group_arity]

  @max_window_seconds 365 * 24 * 60 * 60

  defp window_ms(value) when is_binary(value) do
    case Guardian.Query.Function.Interval.to_seconds(value) do
      {:ok, seconds} when seconds > 0 and seconds <= @max_window_seconds -> seconds * 1_000
      _ -> nil
    end
  end

  defp window_ms(_value) do
    nil
  end

  # Three buckets per window, rounded up to whole milliseconds.
  defp bucket_ms(nil) do
    nil
  end

  defp bucket_ms(window_ms) do
    div(window_ms + 2, 3)
  end

  @doc "Build metadata from a parsed TRACK; Validation rejects invalid operators and windows."
  def new(table, source, %Guardian.AST.Node.Statements.TrackStatement{} = statement) do
    window_ms = window_ms(statement.last_expr.value)
    digest = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

    %__MODULE__{
      identity: {table, statement.field.name, digest},
      operator: {statement.aggregate_expr.name, length(statement.aggregate_expr.args)},
      window_ms: window_ms,
      bucket_ms: bucket_ms(window_ms),
      group_arity: length(statement.by_exprs),
    }
  end

  @doc """
  The target's input to dependent resolved plan hashes. Resolution encodes it
  deterministically. Changing these keys or values changes dependent resolved
  plan hashes.
  """
  def hash_term(%__MODULE__{} = definition) do
    %{
      __struct__: __MODULE__,
      identity: definition.identity,
      operator: definition.operator,
      window_ms: definition.window_ms,
      bucket_ms: definition.bucket_ms,
      group_arity: definition.group_arity,
    }
  end
end

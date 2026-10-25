defmodule Guardian.Rules.CounterDefinition do
  @moduledoc "Immutable counter metadata bound into TRACK and LOOKUP plans."
  @enforce_keys [:identity, :operator, :aggregation, :window_ms, :bucket_ms, :group_arity]
  defstruct [:identity, :operator, :aggregation, :window_ms, :bucket_ms, :group_arity]

  @max_window_seconds 365 * 24 * 60 * 60

  def window_ms(value) when is_binary(value) do
    case Guardian.Query.Function.Interval.to_seconds(value) do
      {:ok, seconds} when seconds > 0 and seconds <= @max_window_seconds -> seconds * 1_000
      _ -> nil
    end
  end

  def window_ms(_value) do
    nil
  end

  @doc "Three buckets per window, rounded up to whole milliseconds."
  def bucket_ms(nil) do
    nil
  end

  def bucket_ms(window_ms) do
    div(window_ms + 2, 3)
  end

  def from_track(%Guardian.Rules.Step.Track{} = step) do
    %__MODULE__{
      identity: step.identity,
      operator: step.operator,
      aggregation: step.aggregation,
      window_ms: step.window_ms,
      bucket_ms: step.bucket_ms,
      group_arity: length(step.by_exprs),
    }
  end

  @doc """
  Legacy struct-shaped plan hash input, excluding derived configuration.
  Changing these keys or values changes dependent resolved plan hashes.
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

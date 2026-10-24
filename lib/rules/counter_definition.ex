defmodule Rules.CounterDefinition do
  @moduledoc "Immutable counter metadata bound into TRACK and LOOKUP plans."
  @enforce_keys [:identity, :operator, :window_ms, :bucket_ms, :group_arity]
  defstruct [:identity, :operator, :window_ms, :bucket_ms, :group_arity]

  @max_window_seconds 365 * 24 * 60 * 60

  def window_ms(value) when is_binary(value) do
    case Query.Function.Interval.to_seconds(value) do
      {:ok, seconds} when seconds > 0 and seconds <= @max_window_seconds -> seconds * 1_000
      _ -> nil
    end
  end

  def window_ms(_value), do: nil

  @doc "Three buckets per window, rounded up to whole milliseconds."
  def bucket_ms(nil), do: nil
  def bucket_ms(window_ms), do: div(window_ms + 2, 3)

  def from_track(%Rules.Step.Track{} = step) do
    %__MODULE__{
      identity: step.identity,
      operator: step.operator,
      window_ms: step.window_ms,
      bucket_ms: step.bucket_ms,
      group_arity: length(step.by_exprs),
    }
  end
end

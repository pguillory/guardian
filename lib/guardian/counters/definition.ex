defmodule Guardian.Counters.Definition do
  @moduledoc """
  One counter's immutable definition: identity, operator, window and bucket sizes and
  grouping arity. Rules builds it from a parsed TRACK and binds LOOKUPs to it;
  `Guardian.Counters.Execution` reads its identity, operator and sizes.
  """
  alias Guardian.Aggregation

  @enforce_keys [:identity, :operator, :window_ms, :bucket_ms, :group_arity]
  defstruct [:identity, :operator, :window_ms, :bucket_ms, :group_arity]

  @type t :: %__MODULE__{
          identity: term(),
          operator: {String.t(), non_neg_integer()},
          window_ms: pos_integer() | nil,
          bucket_ms: pos_integer() | nil,
          group_arity: non_neg_integer(),
        }

  @doc """
  A definition with three buckets per window, rounded up to whole milliseconds. A nil
  window (an invalid LAST, which Rules validation reports before anything runs) has
  a nil bucket.
  """
  @spec new(term(), {String.t(), non_neg_integer()}, pos_integer() | nil, non_neg_integer()) ::
          t()
  def new(identity, operator, window_ms, group_arity) do
    %__MODULE__{
      identity: identity,
      operator: operator,
      window_ms: window_ms,
      bucket_ms: bucket_ms(window_ms),
      group_arity: group_arity,
    }
  end

  defp bucket_ms(nil) do
    nil
  end

  defp bucket_ms(window_ms) do
    div(window_ms + 2, 3)
  end

  @doc """
  The operator's shared aggregation. `Aggregation.default/1` of it is the missing
  result, written for a failed counter statement.
  """
  @spec aggregation(t()) :: Aggregation.t()
  def aggregation(%__MODULE__{operator: {name, _arity}}) do
    Aggregation.fetch!(name)
  end
end

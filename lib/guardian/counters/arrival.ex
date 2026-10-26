defmodule Guardian.Counters.Arrival do
  @moduledoc """
  An event's private arrival coordinates, never row fields: Unix milliseconds choose
  its counter buckets, and local monotonic milliseconds anchor its mutation expiries.
  """
  @enforce_keys [:unix_ms, :monotonic_ms]
  defstruct [:unix_ms, :monotonic_ms]

  @type t :: %__MODULE__{unix_ms: integer(), monotonic_ms: integer()}

  @spec now() :: t()
  def now do
    %__MODULE__{
      unix_ms: System.system_time(:millisecond),
      monotonic_ms: System.monotonic_time(:millisecond),
    }
  end
end

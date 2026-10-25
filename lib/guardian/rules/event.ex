defmodule Guardian.Rules.Event do
  @moduledoc "Private arrival coordinates and per-event counter routing context, never row fields."
  alias Guardian.Counters.{Client, Context}
  @enforce_keys [:arrival_ms, :monotonic_ms]
  defstruct [:arrival_ms, :monotonic_ms, :counters]

  @type t :: %__MODULE__{
          arrival_ms: integer(),
          monotonic_ms: integer(),
          counters: Context.t() | nil,
        }

  @spec arrival() :: t()
  def arrival do
    %__MODULE__{
      arrival_ms: System.system_time(:millisecond),
      monotonic_ms: System.monotonic_time(:millisecond),
    }
  end

  @spec start(t(), Context.batch(), [Context.option()]) :: t()
  def start(%__MODULE__{} = arrival, batch, opts \\ []) do
    %{arrival | counters: Client.new_event(batch, opts)}
  end

  @spec new() :: t()
  def new do
    start(arrival(), Client.new_batch())
  end
end

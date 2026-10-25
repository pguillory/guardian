defmodule Guardian.Rules.Event do
  @moduledoc "Private arrival coordinates and per-event counter routing context, never row fields."
  @enforce_keys [:arrival_ms, :monotonic_ms]
  defstruct [:arrival_ms, :monotonic_ms, :counters]

  def arrival do
    %__MODULE__{
      arrival_ms: System.system_time(:millisecond),
      monotonic_ms: System.monotonic_time(:millisecond),
    }
  end

  def start(%__MODULE__{} = arrival, batch, opts \\ []) do
    %{arrival | counters: Guardian.Counters.Cluster.new_event(batch, opts)}
  end

  def new, do: start(arrival(), Guardian.Counters.Cluster.new_batch())
end

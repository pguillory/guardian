defmodule Guardian.Rules.Event do
  @moduledoc """
  What a compiled rule module gets besides the row: the event's private arrival
  coordinates and its per-event counter routing context, never row fields.
  """
  alias Guardian.Counters.{Arrival, Client, Context}
  @enforce_keys [:arrival, :counters]
  defstruct [:arrival, :counters]

  @type t :: %__MODULE__{arrival: Arrival.t(), counters: Context.t()}

  @spec start(Arrival.t(), Context.batch(), [Context.option()]) :: t()
  def start(%Arrival{} = arrival, batch, opts \\ []) do
    %__MODULE__{arrival: arrival, counters: Client.new_event(batch, opts)}
  end

  @spec new() :: t()
  def new do
    start(Arrival.now(), Client.new_batch())
  end
end

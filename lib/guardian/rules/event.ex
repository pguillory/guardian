defmodule Guardian.Rules.Event do
  @moduledoc """
  What a compiled rule module gets besides the row: the event's private arrival
  coordinates and its per-event counter routing context, never row fields.
  """
  alias Guardian.Counters.Arrival
  alias Guardian.Counters.Client
  alias Guardian.Counters.Context
  @enforce_keys [:arrival, :counters]
  defstruct [:arrival, :counters]

  @type t :: %__MODULE__{arrival: Arrival.t(), counters: Context.t()}

  @spec start(Arrival.t(), [Context.option()]) :: t()
  def start(%Arrival{} = arrival, opts \\ []) do
    %__MODULE__{arrival: arrival, counters: Client.new_event(opts)}
  end

  @spec new() :: t()
  def new do
    start(Arrival.now())
  end
end

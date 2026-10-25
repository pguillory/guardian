defmodule Guardian.Counters.Client do
  @moduledoc """
  Availability-first facade for ephemeral counter batches.

  Keep new_batch/0 outside replaceable rule workers and create one new_event/2
  per event. Errors remain fixed atoms; Rules supplies aggregate defaults. Never
  retry an uncertain mutation. Transport and Budget are internal collaborators.
  """
  alias Guardian.Counters.{Budget, Context, Transport}

  @spec new_batch() :: Context.batch()
  defdelegate new_batch(), to: Budget

  @doc "Test options may shorten deadlines or substitute members/store/cooldown table."
  @spec new_event(Context.batch(), [Context.option()]) :: Context.t()
  defdelegate new_event(batch, opts \\ []), to: Context, as: :new

  @spec batch(map(), Context.t()) :: map()
  defdelegate batch(operations, event), to: Transport
end

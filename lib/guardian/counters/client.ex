defmodule Guardian.Counters.Client do
  @moduledoc """
  Availability-first facade for ephemeral counter batches.

  Keep new_batch/0 outside replaceable rule workers and create one new_event/2
  per event. Errors remain fixed atoms; Rules supplies aggregate defaults. Never
  retry an uncertain mutation. Transport and Budget are internal collaborators.
  """
  alias Guardian.Counters.{Budget, Transport}

  defdelegate new_batch(), to: Budget

  @doc "Test options may shorten deadlines or substitute members/store/cooldown table."
  def new_event(batch, opts \\ []) do
    # Start the event deadline before snapshotting membership.
    budget = Budget.new_event(batch, opts)

    Map.merge(budget, %{
      members: Keyword.get_lazy(opts, :members, fn -> [node() | Node.list()] end),
      store: Keyword.get(opts, :store, Guardian.Counters.Store),
    })
  end

  defdelegate batch(operations, event), to: Transport
end

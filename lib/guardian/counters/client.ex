defmodule Guardian.Counters.Client do
  @moduledoc """
  Availability-first facade for routing and dispatching ephemeral counter rounds,
  used by `Guardian.Counters.Execution`'s round loop.

  Keep new_batch/0 outside replaceable rule workers and create one new_event/2
  per event. Errors remain fixed atoms; Rules supplies aggregate defaults. Never
  retry an uncertain mutation. Transport and Budget are internal collaborators.
  """
  alias Guardian.Counters.Budget
  alias Guardian.Counters.Context
  alias Guardian.Counters.Transport

  @spec new_batch() :: Context.batch()
  defdelegate new_batch(), to: Budget

  @doc "Test options may shorten deadlines or substitute members/store/cooldown table."
  @spec new_event(Context.batch(), [Context.option()]) :: Context.t()
  defdelegate new_event(batch, opts \\ []), to: Context, as: :new

  @doc "An operation's owner node, or `{:error, :invalid_request}` for a malformed one."
  @spec route(tuple(), Context.t()) :: {:ok, node()} | {:error, :invalid_request}
  defdelegate route(operation, event), to: Transport

  @doc """
  Runs one round's routed owner batches, `[{owner, operations}]` with owners unique
  and in dispatch order (`Guardian.Counters.Execution` sorts them), as concurrent
  owner pipelines within the shared budgets.
  Returns `[{owner, responses}]` in the same order, one response per operation.
  Pass only operations that `route/2` accepted, grouped under their owner.
  """
  @spec dispatch([{node(), [tuple()]}], Context.t()) :: [{node(), [term()]}]
  defdelegate dispatch(batches, event), to: Transport
end

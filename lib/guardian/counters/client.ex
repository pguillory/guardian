defmodule Guardian.Counters.Client do
  @moduledoc """
  Availability-first client for ephemeral counters, used by
  `Guardian.Counters.Execution`'s round loop, which doesn't know that operations are
  spread across owner nodes: only this module and below do.

  Create one new_event/1 per event. Errors remain fixed atoms; Rules supplies aggregate
  defaults. Never retry an uncertain mutation. Transport is an internal collaborator.
  """
  alias Guardian.Counters.Context
  alias Guardian.Counters.Transport
  alias Guardian.Lists

  @doc "Test options may replace the call timeout or substitute members/store."
  @spec new_event([Context.option()]) :: Context.t()
  defdelegate new_event(opts \\ []), to: Context, as: :new

  @doc """
  Runs one list of operations and returns one response per operation, in the same
  order. It routes each operation to its owner, groups them by owner and runs each
  owner's pipeline concurrently, each within the call timeout. `Guardian.Lists.group/1`
  is the one place that orders owners: it sorts them ascending, keeping each owner's
  operations in input order.

  A malformed operation's `{:error, :invalid_request}` is its response. Bad membership
  is a programming error and raises.
  """
  @spec batch([term()], Context.t()) :: [term()]
  def batch(operations, %Context{} = event) do
    routes = Enum.map(operations, &route(&1, event))
    routed = Lists.filter(routes, &routed?/1)
    owners = Enum.map(routed, fn {:ok, owner, _operation} -> owner end)

    routed
    |> Enum.map(fn {:ok, owner, operation} -> {owner, operation} end)
    |> Lists.group()
    |> Transport.dispatch(event)
    |> Lists.ungroup(owners)
    |> Lists.unfilter(routes, &routed?/1)
  end

  defp route(operation, event) do
    case Transport.route(operation, event) do
      {:ok, owner} -> {:ok, owner, operation}
      error -> error
    end
  end

  defp routed?(route) do
    match?({:ok, _owner, _operation}, route)
  end
end

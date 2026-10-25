defmodule Guardian.Cluster.NodeError do
  @moduledoc """
  Raised when a cluster-wide operation fails or times out on one or more connected
  nodes. `failures` is a list of `{node, {class, reason}}` as returned by
  `:erpc.multicall/5`.
  """

  defexception [:operation, failures: []]

  @impl true
  def message(%__MODULE__{} = error) do
    failures =
      Enum.map_join(error.failures, ", ", fn {node, {class, reason}} ->
        "#{node} (#{class}: #{inspect(reason, limit: 5)})"
      end)

    "Cluster metadata lookup #{error.operation} failed on #{failures}"
  end
end

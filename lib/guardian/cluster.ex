defmodule Guardian.Cluster do
  @moduledoc """
  Distributed query coordination across connected Guardian nodes.

  Discovery is handled by `DNSCluster`, started by `Guardian.Application` when
  `:guardian, :dns_cluster_query` is set (`DNS_CLUSTER_QUERY`; on Fly.io,
  `<app>.internal` by default). Every node
  keeps its own segments on local disk; queries fan out to the nodes connected at the
  time they run.
  """

  # How long a peer has to answer whether its Storage is ready.
  @ready_timeout 5_000

  @doc """
  This node plus every connected peer whose Storage has finished starting.

  Erlang distribution comes up before Guardian's applications, so a booting peer is
  connected while it still loads segments. Asking it for schemas or segments then
  fails, so it is left out until `Guardian.Storage.ready?/0` answers `true`, like a
  peer that is not connected. A peer that fails or does not answer within
  #{@ready_timeout} ms is left out as well.
  """
  def connected_nodes do
    peers = Node.list()
    answers = :erpc.multicall(peers, Guardian.Storage, :ready?, [], @ready_timeout)
    ready_peers = for {peer, {:ok, true}} <- Enum.zip(peers, answers), do: peer
    [Node.self() | ready_peers]
  end

  @doc """
  Child spec for DNS-based peer discovery. Returns `:ignore` from `start_link` when no
  query is configured (`DNS_CLUSTER_QUERY`), so nothing runs in dev, test, or a single
  node.

  With a query, this node's name must be `<basename>@<ip>` with the IP written exactly
  as DNSCluster writes the addresses the query resolves to (`:inet.ntoa/1`), because
  DNSCluster connects to `<basename>@<resolved ip>` and a peer answers only to its own
  name. Raises otherwise, so a misnamed node fails at boot instead of silently never
  joining. The record type follows the address: AAAA for IPv6 (as on Fly, whose
  `.internal` names publish only AAAA records), A for IPv4.

  `query` defaults to the configured `:dns_cluster_query`.
  """
  def discovery_child_spec(
        query \\ Application.get_env(:guardian, :dns_cluster_query),
        node_name \\ node()
      ) do
    case query do
      nil ->
        {DNSCluster, query: :ignore}

      query ->
        {DNSCluster, query: query, resource_types: dns_resource_types!(node_name)}
    end
  end

  @doc false
  def dns_resource_types!(node_name) do
    host = node_name |> Atom.to_string() |> String.split("@", parts: 2) |> Enum.at(1, "")

    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} ->
        canonical = address |> :inet.ntoa() |> to_string()

        cond do
          loopback?(address) ->
            raise_node_name(node_name, "its host is a loopback address")

          canonical != host ->
            raise_node_name(node_name, "write its address as #{canonical}")

          tuple_size(address) == 8 ->
            [:aaaa]

          true ->
            [:a]
        end

      {:error, _} ->
        raise_node_name(node_name, "its host is not an IP address (set GUARDIAN_NODE_HOST)")
    end
  end

  # Loopback and unspecified addresses, including IPv4-mapped IPv6 forms: none of them
  # names a node that other machines can reach.
  defp loopback?({127, _, _, _}) do
    true
  end

  defp loopback?({0, 0, 0, 0}) do
    true
  end

  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}) do
    true
  end

  defp loopback?({0, 0, 0, 0, 0, 0, 0, 0}) do
    true
  end

  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _b}) when a in 0x7F00..0x7FFF do
    true
  end

  defp loopback?(_address) do
    false
  end

  defp raise_node_name(node_name, problem) do
    raise ArgumentError,
          "DNS_CLUSTER_QUERY is set, but this node's name #{node_name} cannot be reached " <>
            "by DNS discovery: #{problem}"
  end
end

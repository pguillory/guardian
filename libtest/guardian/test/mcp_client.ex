defmodule Guardian.Test.MCPClient do
  @moduledoc """
  An MCP client for tests that drive Guardian's MCP endpoint end to end (Anubis
  client).

  Start it with `start/0` from the test process, then call it through this module from
  that process or a task it started:

      MCPClient.start()
      {:ok, response} = MCPClient.call_tool("query", %{"sql" => "SHOW TABLES"})

  Each `start/0` gets its own client, registered under a name of its own, so async tests
  can each run one. Its `client_info` name is unique too (`guardian-test-<n>`): Anubis
  names a private ETS table after it, which a second client with the same name could not
  use.
  """

  # The full-access admin key, as MCP clients are meant to use.
  @api_key Application.compile_env!(:guardian, :admin_api_key)

  @client_key {__MODULE__, :client}

  @doc """
  Starts a client connected to this node's MCP endpoint under the calling test's
  supervisor (`ExUnit.Callbacks.start_supervised/1`, so call it from the test
  process), and waits up to 30 seconds for it to initialize; a failed initialization
  raises, and a slower one exits the calling test. Initializing is an HTTP round trip
  to this node's listener and takes milliseconds, except for the run's first client:
  while every async module starts at once, it waits several seconds for its connection
  and code to load.

  The client registers locally under a unique name, kept in the test process, which the
  calls use. Don't give it a `{:global, _}` name: see
  `Guardian.Query.DistributedStream.ClusterTest`.
  """
  def start do
    n = System.unique_integer([:positive])
    name = :"#{__MODULE__}.#{n}"
    finch = :"#{__MODULE__}.Finch.#{n}"

    # Anubis 2.x clients need a Finch pool started by the caller.
    {:ok, _finch} = ExUnit.Callbacks.start_supervised({Finch, name: finch})

    child_spec =
      Anubis.Client.child_spec(
        name: name,
        client_info: %{"name" => "guardian-test-#{n}", "version" => "0.1.0"},
        protocol_version: "2025-03-26",
        capabilities: %{},
        transport:
          {:streamable_http,
           base_url: "http://localhost:#{Guardian.Web.bound_port()}",
           mcp_path: "/mcp",
           headers: %{"x-api-key" => @api_key},
           finch_name: finch}
      )

    {:ok, _pid} = ExUnit.Callbacks.start_supervised(child_spec)
    Process.put(@client_key, name)

    case Anubis.Client.await_ready(name, timeout: 30_000) do
      :ok -> :ok
      {:error, error} -> raise "MCP client initialization failed: #{inspect(error)}"
    end
  end

  def call_tool(name, arguments) do
    Anubis.Client.call_tool(client(), name, arguments)
  end

  def list_tools do
    Anubis.Client.list_tools(client())
  end

  def list_resources do
    Anubis.Client.list_resources(client())
  end

  def read_resource(uri) do
    Anubis.Client.read_resource(client(), uri)
  end

  def get_server_info do
    Anubis.Client.get_server_info(client())
  end

  # The client this process, or the test that started it, began with start/0.
  defp client do
    Enum.find_value([self() | Process.get(:"$callers", [])], &started_client/1) ||
      raise "no MCP client: call Guardian.Test.MCPClient.start/0 from the test first"
  end

  defp started_client(pid) when pid == self() do
    Process.get(@client_key)
  end

  defp started_client(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> List.keyfind(dictionary, @client_key, 0, {nil, nil}) |> elem(1)
      nil -> nil
    end
  end
end

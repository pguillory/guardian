defmodule Guardian.Test.MCPClient do
  @moduledoc """
  An MCP client for tests that drive Guardian's MCP endpoint end to end (Anubis
  client). It identifies itself as `guardian` version `0.1.0`, which tests read back
  from recorded rows.

  Start it with `start/0` from the test process, then call it through this module:

      MCPClient.start()
      {:ok, response} = MCPClient.call_tool("query", %{"sql" => "SHOW TABLES"})
  """

  # The full-access admin key, as MCP clients are meant to use.
  @api_key Application.compile_env!(:guardian, :admin_api_key)

  @doc """
  Starts a client connected to this node's MCP endpoint under the calling test's
  supervisor (`ExUnit.Callbacks.start_supervised/1`, so call it from the test
  process), and waits up to 3 seconds for it to initialize; a failed initialization
  raises, and a slower one exits the calling test.

  The client registers locally under this module's name, which the calls use. Don't
  give it a `{:global, _}` name: see `Guardian.Query.DistributedStream.ClusterTest`.
  """
  def start do
    # Anubis 2.x clients need a Finch pool started by the caller.
    {:ok, _finch} = ExUnit.Callbacks.start_supervised({Finch, name: __MODULE__.Finch})

    child_spec =
      Anubis.Client.child_spec(
        name: __MODULE__,
        client_info: %{"name" => "guardian", "version" => "0.1.0"},
        protocol_version: "2025-03-26",
        capabilities: %{},
        transport:
          {:streamable_http,
           base_url: "http://localhost:#{Guardian.Web.bound_port()}",
           mcp_path: "/mcp",
           headers: %{"x-api-key" => @api_key},
           finch_name: __MODULE__.Finch}
      )

    {:ok, _pid} = ExUnit.Callbacks.start_supervised(child_spec)

    case Anubis.Client.await_ready(__MODULE__, timeout: 3_000) do
      :ok -> :ok
      {:error, error} -> raise "MCP client initialization failed: #{inspect(error)}"
    end
  end

  def call_tool(name, arguments) do
    Anubis.Client.call_tool(__MODULE__, name, arguments)
  end

  def list_tools do
    Anubis.Client.list_tools(__MODULE__)
  end

  def list_resources do
    Anubis.Client.list_resources(__MODULE__)
  end

  def read_resource(uri) do
    Anubis.Client.read_resource(__MODULE__, uri)
  end

  def get_server_info do
    Anubis.Client.get_server_info(__MODULE__)
  end
end

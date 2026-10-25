defmodule Guardian.MCPTestClient do
  @moduledoc """
  An MCP client for tests that drive Guardian's MCP endpoint end to end (Anubis
  client). It identifies itself as `guardian` version `0.1.0`, which tests read back
  from recorded rows.

  Start it with `start/0` from the test process, then call it by module name:

      MCPTestClient.start()
      {:ok, response} = MCPTestClient.call_tool("query", %{"sql" => "SHOW TABLES"})
  """

  use Anubis.Client,
    name: "guardian",
    version: "0.1.0",
    protocol_version: "2025-03-26",
    capabilities: []

  @api_key Application.compile_env!(:guardian, :api_key)

  @doc """
  Starts a client connected to this node's MCP endpoint under the calling test's
  supervisor (`ExUnit.Callbacks.start_supervised/1`, so call it from the test
  process), and waits for it to initialize: 31 checks, 100 ms apart, then raises.

  The client registers locally under its module name, which the calls use. Don't give
  it a `{:global, _}` name: see `Guardian.Query.DistributedStream.ClusterTest`.
  """
  def start do
    child_spec =
      child_spec(
        transport:
          {:streamable_http,
           base_url: "http://localhost:#{Guardian.Web.bound_port()}",
           mcp_path: "/mcp",
           headers: %{"x-api-key" => @api_key}}
      )

    {:ok, _pid} = ExUnit.Callbacks.start_supervised(child_spec)
    await_init(30)
  end

  # get_server_info/0 returns nil until the client has initialized.
  defp await_init(retries) do
    case get_server_info() do
      nil when retries > 0 ->
        Process.sleep(100)
        await_init(retries - 1)

      nil ->
        raise "MCP client initialization timeout"

      _info ->
        :ok
    end
  end
end

defmodule Guardian.Web.MCP.LogFilter do
  @moduledoc """
  Keeps MCP requests out of Anubis's logs.

  When a request outlasts Anubis's call timeout or its session exits mid-call, the
  Streamable HTTP transport logs the call's exit reason at error
  (`session_call_failed`). That reason holds the whole call: `{:mcp_request, message,
  context}`, with the JSON-RPC message (SQL, events, rules) and the request's headers.
  This `:logger` primary filter rewrites any line Anubis logs that contains such a call
  to name only the exit reason (`timeout`, `noproc`, ...). Anubis formats the reason
  into the message text before logging, so the filter has only that text to match;
  recheck on an Anubis upgrade.

  `Guardian.Web.MCP.Router` also drops the `x-api-key` header once the key is checked,
  so the key reaches no Anubis state or log either way.
  """

  @filter_id :guardian_mcp_requests

  # Anubis inspects the call into its message: `{:mcp_request, %{...}, %{...}}`.
  @marker "{:mcp_request,"

  @doc "Adds the filter to `:logger`; adding it again is a no-op."
  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  @doc false
  def filter(%{meta: %{mfa: {Anubis.Logging, _, _}}, msg: {:string, text}} = event, _) do
    text = IO.chardata_to_string(text)

    if String.contains?(text, @marker) do
      %{event | msg: {:string, redacted(text)}}
    else
      :ignore
    end
  end

  def filter(_event, _) do
    :ignore
  end

  # Keeps Anubis's prefix ("MCP transport details") and the exit reason's name.
  defp redacted(text) do
    [prefix | _] = String.split(text, ": ", parts: 2)

    reason =
      case Regex.run(~r/^[^:]+: %\{reason: \{:([a-z_]+),/, text) do
        [_, reason] -> reason
        nil -> "unknown"
      end

    "#{prefix}: MCP call exited (#{reason}); request redacted"
  end
end

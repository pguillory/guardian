defmodule Web.Ingest do
  @moduledoc """
  Shared request validation and ordered ingestion results for HTTP and MCP.
  """

  def send_events(params) do
    with {:ok, table, events, return_keys} <- validate_ingest_request(params) do
      results =
        Engine.ingest_events(table, events)
        |> Enum.map(fn
          {:ok, event} -> %{success: true, event: filter_keys(event, return_keys)}
          {:error, message} -> %{success: false, error: message}
        end)

      {:ok, %{status: 200, results: results}}
    end
  end

  defp validate_ingest_request(params) when is_map(params) do
    table = Map.get(params, "table")
    events = Map.get(params, "events")
    return_keys = Map.get(params, "return_keys")

    cond do
      not Engine.valid_table_name?(table) ->
        {:error, Exception.message(%Engine.InvalidTableNameError{table: table})}

      not is_list(events) ->
        {:error, "events must be a list"}

      not valid_return_keys?(return_keys) ->
        {:error, "return_keys must be null or a list of strings"}

      true ->
        {:ok, table, events, return_keys}
    end
  end

  defp validate_ingest_request(_params), do: {:error, "arguments must be an object"}

  defp valid_return_keys?(nil), do: true
  defp valid_return_keys?(keys) when is_list(keys), do: Enum.all?(keys, &is_binary/1)
  defp valid_return_keys?(_keys), do: false

  defp filter_keys(event, nil), do: event
  defp filter_keys(event, keys), do: Map.take(event, keys)
end

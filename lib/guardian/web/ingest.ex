defmodule Guardian.Web.Ingest do
  @moduledoc """
  Shared request validation and ordered ingestion results for HTTP and MCP.
  """

  def send_events(params) do
    with {:ok, table, events, return_keys, key} <- validate_ingest_request(params) do
      ingest_fun = fn -> ingest(table, events, return_keys) end

      if key == nil do
        {:ok, ingest_fun.()}
      else
        Guardian.Web.IngestIdempotency.run(table, key, {events, return_keys}, ingest_fun)
      end
    end
  end

  defp ingest(table, events, return_keys) do
    results =
      Guardian.Engine.ingest_events(table, events)
      |> Enum.map(fn
        {:ok, event} -> %{success: true, event: filter_keys(event, return_keys)}
        {:error, message} -> %{success: false, error: message}
      end)

    %{status: 200, results: results}
  end

  defp validate_ingest_request(params) when is_map(params) do
    table = Map.get(params, "table")
    events = Map.get(params, "events")
    return_keys = Map.get(params, "return_keys")
    key = Map.get(params, "idempotency_key")

    cond do
      not Guardian.Engine.valid_table_name?(table) ->
        {:error, Exception.message(%Guardian.Engine.InvalidTableNameError{table: table})}

      not is_list(events) ->
        {:error, "events must be a list"}

      not valid_return_keys?(return_keys) ->
        {:error, "return_keys must be null or a list of strings"}

      not valid_idempotency_key?(key) ->
        {:error, "idempotency_key must be null or a nonempty UTF-8 string of at most 128 bytes"}

      true ->
        {:ok, table, events, return_keys, key}
    end
  end

  defp validate_ingest_request(_params), do: {:error, "arguments must be an object"}

  defp valid_return_keys?(nil), do: true
  defp valid_return_keys?(keys) when is_list(keys), do: Enum.all?(keys, &is_binary/1)
  defp valid_return_keys?(_keys), do: false

  defp valid_idempotency_key?(nil), do: true

  defp valid_idempotency_key?(key) when is_binary(key),
    do: byte_size(key) in 1..128 and String.valid?(key)

  defp valid_idempotency_key?(_key), do: false

  # Every requested key is in the result, null when the event lacks it, so a client can
  # always read the fields it asked for (such as one a rule sets only sometimes).
  defp filter_keys(event, nil), do: event
  defp filter_keys(event, keys), do: Map.new(keys, &{&1, Map.get(event, &1)})
end

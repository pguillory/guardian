defmodule Guardian.Web.Auth do
  @moduledoc """
  How a request's API key is found and checked, for both authenticated routers
  (`Guardian.Web.JsonApi` and `Guardian.Web.MCP.Router`). Guardian is single-user and
  attaches no identity, but its keys differ in scope: the ingest key may only send
  events (`POST /api/json/send_events`); the admin key grants everything. See
  docs/architecture/security.md, section 4.2.
  """

  @typedoc """
  Which configured key a request used: the insert-only `GUARDIAN_INGEST_API_KEY` or
  the full-access `GUARDIAN_ADMIN_API_KEY`.
  """
  @type key() :: :ingest | :admin

  @doc """
  Checks a request's API key against the access it needs. The key is read only from
  the first `x-api-key` header; the query string is never decoded, so a key in the URL
  is never accepted.

  `required` is `:ingest` (event ingestion, which every key grants) or `:full`
  (everything else, which only the admin key grants).

  Returns `{:ok, key}`, with `key` `:ingest` or `:admin` saying which
  configured key it was; `{:error, :missing}` when there is no header;
  `{:error, :unauthorized}` for a key that is wrong, including an empty one; or
  `{:error, :forbidden}` for the ingest key where `:full` is required. Each router
  sends its own error bodies. The conn is not changed.
  """
  @spec check_conn(Plug.Conn.t(), :ingest | :full) ::
          {:ok, key()} | {:error, :missing | :unauthorized | :forbidden}
  def check_conn(conn, required) when required in [:ingest, :full] do
    with {:ok, api_key} <- get_api_key(conn),
         {:ok, key} <- identify_api_key(api_key),
         :ok <- permit(key, required) do
      {:ok, key}
    end
  end

  defp permit(:ingest, :full) do
    {:error, :forbidden}
  end

  defp permit(_key, _required) do
    :ok
  end

  defp get_api_key(conn) do
    case Plug.Conn.get_req_header(conn, "x-api-key") do
      [api_key | _] -> {:ok, api_key}
      [] -> {:error, :missing}
    end
  end

  @doc """
  Says which configured key a supplied one is: `{:ok, :ingest | :admin}`
  or `{:error, :unauthorized}`. Every configured key is compared in constant time,
  with no early return, so timing reveals neither how much of a guess is right nor
  which key matched. Boot guarantees the configured keys are distinct.
  """
  @spec identify_api_key(term()) :: {:ok, key()} | {:error, :unauthorized}
  def identify_api_key(api_key) when is_binary(api_key) do
    matches =
      for {key, configured} <- configured_api_keys(), is_binary(configured) do
        {key,
         byte_size(api_key) == byte_size(configured) and
           Plug.Crypto.secure_compare(api_key, configured)}
      end

    # Boot refuses equal keys; should two ever match anyway (set at runtime), take
    # the narrowest, so a shared value never widens the ingest key's access.
    case for({key, true} <- matches, do: key) do
      [] -> {:error, :unauthorized}
      keys -> {:ok, if(:ingest in keys, do: :ingest, else: hd(keys))}
    end
  end

  # Not a string (headers always are, but the function is public): reject it like a
  # wrong key rather than crashing (and printing it).
  def identify_api_key(_api_key) do
    {:error, :unauthorized}
  end

  # Unset keys are nil. `config/runtime.exs` sets them from GUARDIAN_INGEST_API_KEY and
  # GUARDIAN_ADMIN_API_KEY.
  defp configured_api_keys do
    [
      ingest: Application.get_env(:guardian, :ingest_api_key),
      admin: Application.get_env(:guardian, :admin_api_key),
    ]
  end
end

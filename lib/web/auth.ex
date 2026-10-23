defmodule Web.Auth do
  @moduledoc """
  How a request's API key is found and checked, for both authenticated routers
  (`Web.JsonApi` and `Web.MCP.Router`). Guardian is single-user: a valid key grants
  access to everything and attaches no identity. See docs/architecture/security.md,
  section 4.2.
  """

  require Logger

  @doc """
  Checks a request's API key: the first `x-api-key` header if there is one, otherwise,
  only when query keys are allowed, the `api_key` query parameter.

  Query keys are off unless `:guardian, :allow_query_api_key` is true (set from
  `GUARDIAN_ALLOW_QUERY_API_KEY=true`), because URLs end up in logs and history more
  readily than headers. While they are off the query string is never decoded, so a
  request without the header is `{:error, :missing}` whatever its query string.

  Returns `{:ok, method}` with `method` `:header` or `:query`, saying where the valid
  key was found; `{:error, :missing}` when there is no key to check;
  `{:error, :unauthorized}` for a key that is wrong, including an empty or structured
  one; or, with query keys allowed, `{:error, {:invalid_query, status}}` when there is
  no header and the query string cannot be decoded (`Plug.Conn.InvalidQueryError`:
  invalid UTF-8, nesting over 32, or over the length limit), with the exception's
  status (400, or 414 over the limit). Each router sends its own error bodies. The
  conn is not changed.
  """
  @spec check_conn(Plug.Conn.t()) ::
          {:ok, :header | :query}
          | {:error, :missing | :unauthorized | {:invalid_query, 400 | 414}}
  def check_conn(conn) do
    with {:ok, method, api_key} <- get_api_key(conn),
         :ok <- authorize_api_key(api_key) do
      {:ok, method}
    end
  rescue
    # Plug's message names only the offending byte or limit; it is not logged.
    error in Plug.Conn.InvalidQueryError ->
      {:error, {:invalid_query, Plug.Exception.status(error)}}
  end

  @doc """
  Whether the `api_key` query parameter is accepted (`GUARDIAN_ALLOW_QUERY_API_KEY`).
  """
  def query_api_key_allowed? do
    Application.get_env(:guardian, :allow_query_api_key, false) == true
  end

  @query_key_log_interval_ms 60_000

  @doc """
  Logs that a request on `path` authenticated with the `api_key` query parameter, at
  most once per #{div(@query_key_log_interval_ms, 1000)} s per node. Names only the
  path, never the key.
  """
  def note_query_key_use(path) do
    now = System.monotonic_time(:millisecond)
    last_logged = query_key_log_atomics()
    last = :atomics.get(last_logged, 1)

    # Whoever swaps the old timestamp for the new one logs; concurrent requests lose.
    if now - last >= @query_key_log_interval_ms and
         :atomics.compare_exchange(last_logged, 1, last, now) == :ok do
      Logger.info("A request on #{path} authenticated with the api_key query parameter")
    end

    :ok
  end

  # One atomics cell holding the last log time, created on first use as if the last log
  # were a full interval ago. Only that first use writes the persistent term.
  defp query_key_log_atomics do
    key = {__MODULE__, :query_key_logged_at}

    case :persistent_term.get(key, nil) do
      nil ->
        ref = :atomics.new(1, signed: true)
        :atomics.put(ref, 1, System.monotonic_time(:millisecond) - @query_key_log_interval_ms)
        :persistent_term.put(key, ref)
        ref

      ref ->
        ref
    end
  end

  defp get_api_key(conn) do
    case Plug.Conn.get_req_header(conn, "x-api-key") do
      [api_key | _] ->
        {:ok, :header, api_key}

      _ ->
        if query_api_key_allowed?() do
          conn = Plug.Conn.fetch_query_params(conn)

          case conn.query_params do
            %{"api_key" => api_key} -> {:ok, :query, api_key}
            _ -> {:error, :missing}
          end
        else
          {:error, :missing}
        end
    end
  end

  @doc """
  Compares a supplied key with the configured `:guardian, :api_key` in constant time.
  Returns `:ok` or `{:error, :unauthorized}`.
  """
  def authorize_api_key(api_key) when is_binary(api_key) do
    configured_api_key = Application.fetch_env!(:guardian, :api_key)

    if byte_size(api_key) == byte_size(configured_api_key) and
         Plug.Crypto.secure_compare(api_key, configured_api_key) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  # Plug decodes `?api_key[]=x` to a list and `?api_key[a]=x` to a map. Neither is a
  # key; reject it like a wrong one rather than crashing (and printing it).
  def authorize_api_key(_api_key), do: {:error, :unauthorized}
end

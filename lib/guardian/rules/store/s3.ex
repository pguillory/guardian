defmodule Guardian.Rules.Store.S3 do
  @moduledoc """
  Rule files in an S3-compatible bucket (Cloudflare R2, or any S3 API), signed with
  SigV4 by Req (`service: :s3`; region `auto` for R2). Objects are
  `<prefix><table>/<name>.gsql` plus the write lock, addressed path-style
  (`<endpoint>/<bucket>/<key>`).

  Credentials are held only in a zero-arity function (`:credentials`), and requests
  carry `{module, function, [that function, region]}` as their signing option, so a
  request or this config, inspected or in a crash report, shows no secret. Every call
  catches everything and returns a `Guardian.Rules.Store` reason naming only a kind (an HTTP
  status, `timeout`, ...): never a body, header, or exception. A VM crash dump still
  contains the secret, as it does every secret Guardian holds.

  Timeouts: 5 s to connect, 15 s to receive. A put or delete also has an overall
  20 s deadline; past it, or when the connection drops after sending, its outcome is
  `{:unknown, kind}`.
  """

  @behaviour Guardian.Rules.Store

  @enforce_keys [:endpoint, :bucket, :region, :prefix, :credentials]
  defstruct [:endpoint, :bucket, :region, :prefix, :credentials]

  @connect_timeout 5_000
  @receive_timeout 15_000
  @write_deadline 20_000

  # Tests shorten these through app env.
  defp receive_timeout,
    do: Application.get_env(:guardian, :rules_s3_receive_timeout_ms, @receive_timeout)

  defp write_deadline,
    do: Application.get_env(:guardian, :rules_s3_write_deadline_ms, @write_deadline)

  defimpl Inspect do
    def inspect(config, _opts) do
      "#Guardian.Rules.Store.S3<#{config.endpoint}/#{config.bucket}/#{config.prefix}>"
    end
  end

  @impl true
  def describe(config), do: "S3 bucket #{config.bucket} at #{config.endpoint}"

  @doc false
  def sigv4_options(credentials, region) do
    {access_key_id, secret_access_key} = credentials.()

    [
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      region: region,
      service: :s3,
    ]
  end

  @impl true
  # Rule sets hold at most 1,000 files; a store that keeps paging past this many is
  # refused rather than followed forever.
  @max_list_pages 20

  def list(config), do: safely(fn -> list_pages(config, nil, [], @max_list_pages) end, :read)

  defp list_pages(_config, _token, _acc, 0), do: {:error, {:failed, "too many objects"}}

  defp list_pages(config, token, acc, pages_left) do
    params =
      [{"list-type", "2"}, {"prefix", config.prefix}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case request(config, :get, bucket_path(config), params: params) do
      {:ok, %{status: 200, body: body}} ->
        {objects, next} = parse_list(body, config.prefix)
        acc = [objects | acc]

        if next,
          do: list_pages(config, next, acc, pages_left - 1),
          else: {:ok, acc |> Enum.concat() |> Enum.sort_by(& &1.key)}

      {:ok, %{status: status}} ->
        {:error, status_reason(status, :list)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get(config, key, etag) do
    safely(
      fn ->
        headers = if etag, do: [{"if-match", quote_etag(etag)}], else: []

        case request(config, :get, object_path(config, key), headers: headers) do
          {:ok, %{status: 200} = response} ->
            {:ok, response.body, %{etag: response_etag(response), age_ms: age_ms(response)}}

          {:ok, %{status: status}} ->
            {:error, status_reason(status, :get)}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      :read
    )
  end

  @impl true
  def put(config, key, body, condition) do
    headers =
      case condition do
        :none -> []
        :absent -> [{"if-none-match", "*"}]
        {:etag, etag} -> [{"if-match", quote_etag(etag)}]
      end

    with_deadline(fn ->
      case request(config, :put, object_path(config, key), headers: headers, body: body) do
        {:ok, %{status: status} = response} when status in 200..299 ->
          {:ok, response_etag(response)}

        {:ok, %{status: status}} ->
          {:error, status_reason(status, :write)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @impl true
  def delete(config, key) do
    with_deadline(fn ->
      case request(config, :delete, object_path(config, key), []) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: 404}} -> :ok
        {:ok, %{status: status}} -> {:error, status_reason(status, :write)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp request(config, method, path, options) do
    request =
      Req.new(
        method: method,
        url: config.endpoint <> path,
        aws_sigv4: {__MODULE__, :sigv4_options, [config.credentials, config.region]},
        retry: false,
        redirect: false,
        decode_body: false,
        compressed: false,
        connect_options: [timeout: @connect_timeout],
        receive_timeout: receive_timeout()
      )

    case Req.request(request, options) do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, transport_reason(exception, method)}
    end
  end

  # Writes whose request may have reached the store have an unknown outcome.
  defp transport_reason(%Req.TransportError{reason: reason}, method) do
    kind = transport_kind(reason)

    cond do
      method == :get -> {:unreachable, kind}
      reason in [:econnrefused, :nxdomain, :ehostunreach, :enetunreach] -> {:unreachable, kind}
      true -> {:unknown, kind}
    end
  end

  defp transport_reason(%mod{}, method) do
    kind = inspect(mod)
    if method == :get, do: {:unreachable, kind}, else: {:unknown, kind}
  end

  defp transport_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp transport_kind({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp transport_kind(_reason), do: "transport error"

  defp status_reason(404, :get), do: :not_found
  defp status_reason(status, _) when status in [409, 412], do: :precondition_failed

  defp status_reason(status, _) when status in [400, 401, 403, 404],
    do: {:misconfigured, "HTTP #{status}"}

  # Rate limited: the store refused the request without processing it, so a read can
  # be retried and a write's outcome is known (nothing saved).
  defp status_reason(429, :write), do: {:failed, "HTTP 429"}
  defp status_reason(429, _), do: {:unreachable, "HTTP 429"}
  defp status_reason(status, :write) when status >= 500, do: {:unknown, "HTTP #{status}"}
  defp status_reason(status, _) when status >= 500, do: {:unreachable, "HTTP #{status}"}
  defp status_reason(status, _), do: {:failed, "HTTP #{status}"}

  # Catches everything, so no request, response or exception leaves this module.
  defp safely(fun, operation) do
    fun.()
  catch
    _kind, _reason ->
      if operation == :read,
        do: {:error, {:unreachable, "client error"}},
        else: {:error, {:unknown, "client error"}}
  end

  defp with_deadline(fun) do
    task = Task.async(fn -> safely(fun, :write) end)

    case Task.yield(task, write_deadline()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, {:unknown, "client error"}}
      nil -> {:error, {:unknown, "deadline"}}
    end
  end

  defp bucket_path(config), do: "/" <> URI.encode(config.bucket, &URI.char_unreserved?/1)

  defp object_path(config, key) do
    encoded =
      (config.prefix <> key)
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))

    bucket_path(config) <> "/" <> encoded
  end

  defp quote_etag(etag), do: ~s("#{etag}")

  defp response_etag(response) do
    case Req.Response.get_header(response, "etag") do
      [etag | _] -> etag |> String.trim_leading("W/") |> String.trim("\"")
      [] -> ""
    end
  end

  # How long ago the object was modified, by the store's clock: its Date header minus
  # Last-Modified. Without a Date header, this node's clock stands in.
  defp age_ms(response) do
    with [modified | _] <- Req.Response.get_header(response, "last-modified"),
         {:ok, modified} <- parse_http_date(modified) do
      now =
        with [date | _] <- Req.Response.get_header(response, "date"),
             {:ok, date} <- parse_http_date(date) do
          date
        else
          _ -> DateTime.utc_now()
        end

      DateTime.diff(now, modified, :millisecond)
    else
      _ -> 0
    end
  end

  @months ~w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]

  @doc false
  def parse_http_date(text) do
    case String.split(text, [" ", ":"], trim: true) do
      [_weekday, day, month, year, hour, minute, second, "GMT"] ->
        with month when is_integer(month) <- Enum.find_index(@months, &(&1 == month)),
             {:ok, date} <-
               Date.new(String.to_integer(year), month + 1, String.to_integer(day)),
             {:ok, time} <-
               Time.new(
                 String.to_integer(hour),
                 String.to_integer(minute),
                 String.to_integer(second)
               ) do
          DateTime.new(date, time)
        else
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc false
  def parse_list(body, prefix) do
    # No entities: the response is the store's, and an entity could expand without
    # bound. Element names still become atoms, so the endpoint is trusted (security.md).
    {document, _rest} =
      :xmerl_scan.string(String.to_charlist(body), quiet: true, allow_entities: false)

    objects =
      for contents <- :xmerl_xpath.string(~c"/ListBucketResult/Contents", document) do
        key = text(contents, ~c"Key")

        %{
          key: String.replace_prefix(key, prefix, ""),
          etag: String.trim(text(contents, ~c"ETag"), "\""),
          size: String.to_integer(text(contents, ~c"Size")),
        }
      end

    next =
      if text(document, ~c"/ListBucketResult/IsTruncated") == "true" do
        text(document, ~c"/ListBucketResult/NextContinuationToken")
      end

    {objects, next}
  end

  defp text(node, path) do
    :xmerl_xpath.string(path ++ ~c"/text()", node)
    |> Enum.map(fn text -> elem(text, 4) end)
    |> IO.chardata_to_string()
  end
end

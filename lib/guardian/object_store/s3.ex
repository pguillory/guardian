defmodule Guardian.ObjectStore.S3 do
  @moduledoc """
  Objects in an S3-compatible bucket (Cloudflare R2, or any S3 API), through `ReqS3`.
  A key `k` is the object `<prefix>k`, addressed path-style
  (`<endpoint>/<bucket>/<prefix>k`; `ReqS3` uses virtual-host style for an
  `s3.amazonaws.com` endpoint). Listing is scoped to the prefix.

  `check_endpoint/1` and `check_prefix/1` are the settings this client is safe with;
  whoever builds the config checks them first.

  A failed call is `:not_found`, `:precondition_failed` or a message, and requests are
  not retried. Timeouts: 5 s to connect, Req's 15 s to receive.
  """

  @behaviour Guardian.ObjectStore

  @enforce_keys [:endpoint, :bucket, :region, :prefix, :access_key_id, :secret_access_key]
  defstruct @enforce_keys

  @connect_timeout 5_000

  @doc """
  Checks an endpoint: `:ok`, `{:error, :not_url}` unless it is an `http(s)://<host>`
  URL with no path, or `{:error, :insecure}` for `http://` anywhere but this machine
  (the host `localhost`, 127.0.0.0/8 or `[::1]`), so no one on the network path can
  read or rewrite what the store returns.
  """
  def check_endpoint(endpoint) do
    uri = URI.parse(endpoint)

    cond do
      uri.scheme not in ["https", "http"] or uri.host in [nil, ""] or uri.path not in [nil, ""] ->
        {:error, :not_url}

      uri.scheme == "http" and not loopback?(uri.host) ->
        {:error, :insecure}

      true ->
        :ok
    end
  end

  # Only the plain loopback forms: `localhost`, 127.0.0.0/8 and ::1. Not a name that
  # merely starts with them, and not an IPv4-mapped IPv6 address.
  defp loopback?("localhost") do
    true
  end

  defp loopback?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  @doc """
  Checks a key prefix: `:ok`, `{:error, :no_trailing_slash}` for a non-empty prefix
  not ending in `/`, or `{:error, :invalid_characters}` unless it uses only letters,
  digits and `. _ ~ / -`.
  """
  def check_prefix(prefix) do
    cond do
      prefix != "" and not String.ends_with?(prefix, "/") -> {:error, :no_trailing_slash}
      not String.match?(prefix, ~r{\A[A-Za-z0-9._~/-]*\z}) -> {:error, :invalid_characters}
      true -> :ok
    end
  end

  @impl true
  def describe(config) do
    "S3 bucket #{config.bucket} at #{config.endpoint}"
  end

  @impl true
  def list(config) do
    list_pages(config, nil, [])
  end

  # The bare bucket URL is what makes ReqS3 parse the listing's XML.
  defp list_pages(config, token, pages) do
    params =
      [{"list-type", "2"}, {"prefix", config.prefix}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case request(config, :get, "s3://#{config.bucket}", params: params) do
      {:ok, %{status: 200, body: %{"ListBucketResult" => listing}}} ->
        pages = [Enum.map(listing["Contents"] || [], &object(&1, config.prefix)) | pages]

        if listing["IsTruncated"] == "true" do
          list_pages(config, listing["NextContinuationToken"], pages)
        else
          {:ok, pages |> Enum.concat() |> Enum.sort_by(& &1.key)}
        end

      {:ok, %{status: status}} ->
        {:error, status_error(status)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp object(contents, prefix) do
    %{
      key: String.replace_prefix(contents["Key"], prefix, ""),
      etag: String.trim(contents["ETag"], "\""),
      size: String.to_integer(contents["Size"]),
    }
  end

  @impl true
  def get(config, key, etag) do
    headers = if etag, do: [{"if-match", quote_etag(etag)}], else: []

    # Bytes as stored, whatever the object's name or content type suggests.
    case request(config, :get, object_url(config, key), headers: headers, decode_body: false) do
      {:ok, %{status: 200} = response} ->
        {:ok, response.body, %{etag: response_etag(response), age_ms: age_ms(response)}}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, status_error(status)}

      {:error, message} ->
        {:error, message}
    end
  end

  @impl true
  def put(config, key, body, condition) do
    headers =
      case condition do
        :none -> []
        :absent -> [{"if-none-match", "*"}]
        {:etag, etag} -> [{"if-match", quote_etag(etag)}]
      end

    case request(config, :put, object_url(config, key), headers: headers, body: body) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response_etag(response)}

      {:ok, %{status: status}} ->
        {:error, status_error(status)}

      {:error, message} ->
        {:error, message}
    end
  end

  @impl true
  def delete(config, key) do
    case request(config, :delete, object_url(config, key), []) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %{status: status}} -> {:error, status_error(status)}
      {:error, message} -> {:error, message}
    end
  end

  defp request(config, method, url, options) do
    request =
      [
        method: method,
        url: url,
        aws_sigv4: [
          access_key_id: config.access_key_id,
          secret_access_key: config.secret_access_key,
          region: config.region,
        ],
        retry: false,
        redirect: false,
        compressed: false,
        connect_options: [timeout: @connect_timeout],
      ]
      |> Req.new()
      |> ReqS3.attach(aws_endpoint_url_s3: config.endpoint)

    case Req.request(request, options) do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, "store request failed (#{Exception.message(exception)})"}
    end
  end

  defp status_error(status) when status in [409, 412] do
    :precondition_failed
  end

  defp status_error(status) do
    "store request failed (HTTP #{status})"
  end

  defp object_url(config, key) do
    encoded =
      (config.prefix <> key)
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))

    "s3://#{config.bucket}/#{encoded}"
  end

  defp quote_etag(etag) do
    ~s("#{etag}")
  end

  defp response_etag(response) do
    case Req.Response.get_header(response, "etag") do
      [etag | _] -> etag |> String.trim_leading("W/") |> String.trim("\"")
      [] -> ""
    end
  end

  # How long ago the object was modified, by the store's clock: its Date header minus
  # Last-Modified. Without a Date header, this node's clock stands in.
  defp age_ms(response) do
    {:ok, modified} = http_date(response, "last-modified")

    now =
      case http_date(response, "date") do
        {:ok, date} -> date
        :error -> DateTime.utc_now()
      end

    DateTime.diff(now, modified, :millisecond)
  end

  defp http_date(response, header) do
    with [text | _] <- Req.Response.get_header(response, header),
         {:ok, date} <- Req.Utils.parse_http_date(text) do
      {:ok, date}
    else
      _ -> :error
    end
  end
end

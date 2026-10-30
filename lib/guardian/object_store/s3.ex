defmodule Guardian.ObjectStore.S3 do
  @moduledoc """
  Objects in an S3-compatible bucket (Cloudflare R2, or any S3 API), signed with
  SigV4 by Req (`service: :s3`; region `auto` for R2). A key `k` is the object
  `<prefix>k`, addressed path-style (`<endpoint>/<bucket>/<prefix>k`); listing is
  scoped to the prefix and bounded to `max_list_pages` pages (default 20, 1,000
  objects a page on S3), refusing a store that keeps paging past it.

  `check_endpoint/1` and `check_prefix/1` are the settings this client is safe with;
  whoever builds the config checks them first.

  Credentials are held only in a zero-arity function (`:credentials`), and requests
  carry `{module, function, [that function, region]}` as their signing option, so a
  request or this config, inspected or in a crash report, shows no secret. Every store
  failure is a `Guardian.ObjectStore` reason naming only a kind (an HTTP status,
  `timeout`, ...): never a body or header. A bug raises. A VM crash dump still contains
  the secret, as it does every secret Guardian holds.

  Timeouts: 5 s to connect, 15 s to receive. A put or delete also has an overall
  20 s deadline; past it, or when the connection drops after sending, its outcome is
  `{:unknown, kind}`.
  """

  @behaviour Guardian.ObjectStore

  @enforce_keys [:endpoint, :bucket, :region, :prefix, :credentials]
  defstruct [:endpoint, :bucket, :region, :prefix, :credentials, max_list_pages: 20]

  @connect_timeout 5_000
  @receive_timeout 15_000
  @write_deadline 20_000

  # Tests shorten these through app env.
  defp receive_timeout do
    Application.get_env(:guardian, :object_store_s3_receive_timeout_ms, @receive_timeout)
  end

  @doc "The overall put/delete deadline in milliseconds; tests may override it through app env."
  def write_deadline_ms do
    Application.get_env(:guardian, :object_store_s3_write_deadline_ms, @write_deadline)
  end

  defimpl Inspect do
    def inspect(config, _opts) do
      "#Guardian.ObjectStore.S3<#{config.endpoint}/#{config.bucket}/#{config.prefix}>"
    end
  end

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
  def shared?(_config) do
    true
  end

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
  def list(config) do
    list_pages(config, nil, [], config.max_list_pages)
  end

  defp list_pages(_config, _token, _acc, pages_left) when pages_left <= 0 do
    {:error, {:failed, "too many objects"}}
  end

  defp list_pages(config, token, acc, pages_left) do
    params =
      [{"list-type", "2"}, {"prefix", config.prefix}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case request(config, :get, bucket_path(config), params: params) do
      {:ok, %{status: 200, body: body}} ->
        with {:ok, objects, next} <- parse_list(body, config.prefix) do
          acc = [objects | acc]

          if next,
            do: list_pages(config, next, acc, pages_left - 1),
            else: {:ok, acc |> Enum.concat() |> Enum.sort_by(& &1.key)}
        end

      {:ok, %{status: status}} ->
        {:error, status_reason(status, :list)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get(config, key, etag) do
    headers = if etag, do: [{"if-match", quote_etag(etag)}], else: []

    case request(config, :get, object_path(config, key), headers: headers) do
      {:ok, %{status: 200} = response} ->
        {:ok, response.body, %{etag: response_etag(response), age_ms: age_ms(response)}}

      {:ok, %{status: status}} ->
        {:error, status_reason(status, :get)}

      {:error, reason} ->
        {:error, reason}
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

  defp transport_kind(reason) when is_atom(reason) do
    Atom.to_string(reason)
  end

  defp transport_kind({kind, _}) when is_atom(kind) do
    Atom.to_string(kind)
  end

  defp transport_kind(_reason) do
    "transport error"
  end

  defp status_reason(404, :get) do
    :not_found
  end

  defp status_reason(status, _) when status in [409, 412] do
    :precondition_failed
  end

  defp status_reason(status, _) when status in [400, 401, 403, 404] do
    {:misconfigured, "HTTP #{status}"}
  end

  # Rate limited: the store refused the request without processing it, so a read can
  # be retried and a write's outcome is known (nothing saved).
  defp status_reason(429, :write) do
    {:failed, "HTTP 429"}
  end

  defp status_reason(429, _) do
    {:unreachable, "HTTP 429"}
  end

  defp status_reason(status, :write) when status >= 500 do
    {:unknown, "HTTP #{status}"}
  end

  defp status_reason(status, _) when status >= 500 do
    {:unreachable, "HTTP #{status}"}
  end

  defp status_reason(status, _) do
    {:failed, "HTTP #{status}"}
  end

  defp with_deadline(fun) do
    task = Task.async(fun)

    case Task.yield(task, write_deadline_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, {:unknown, "deadline"}}
    end
  end

  defp bucket_path(config) do
    "/" <> URI.encode(config.bucket, &URI.char_unreserved?/1)
  end

  defp object_path(config, key) do
    encoded =
      (config.prefix <> key)
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))

    bucket_path(config) <> "/" <> encoded
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
  # nil when the response has no Last-Modified this can parse: an age of 0 would make a
  # stale lock look fresh forever.
  @doc false
  def age_ms(response) do
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
      _ -> nil
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
    # Value parsing: a date from the store whose fields aren't numbers.
    ArgumentError -> :error
  end

  # A store's garbage answer is an expected outcome, so it is `{:error, reason}`, never a
  # crash: Rules.Server polls this on every node.
  @malformed_listing {:error, {:unreachable, "malformed listing"}}

  @doc false
  def parse_list(body, prefix) do
    if String.valid?(body), do: parse_listing(body, prefix), else: @malformed_listing
  end

  defp parse_listing(body, prefix) do
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
          size: parse_size(text(contents, ~c"Size")),
        }
      end

    next =
      if text(document, ~c"/ListBucketResult/IsTruncated") == "true" do
        text(document, ~c"/ListBucketResult/NextContinuationToken")
      end

    if Enum.any?(objects, &is_nil(&1.size)), do: @malformed_listing, else: {:ok, objects, next}
  catch
    :exit, {:fatal, _reason} -> @malformed_listing
  end

  defp parse_size(text) do
    case Integer.parse(text) do
      {size, ""} -> size
      _ -> nil
    end
  end

  defp text(node, path) do
    :xmerl_xpath.string(path ++ ~c"/text()", node)
    |> Enum.map(fn text -> elem(text, 4) end)
    |> IO.chardata_to_string()
  end
end

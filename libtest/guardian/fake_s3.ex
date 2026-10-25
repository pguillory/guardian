defmodule Guardian.FakeS3 do
  @moduledoc """
  A small S3-compatible server for rule store tests: ListObjectsV2 (with pagination),
  GET, PUT and DELETE of objects in one bucket, `If-Match` and `If-None-Match: *`, and
  a Date header. It checks every request's SigV4 signature with its own implementation
  of the canonical request (independent of Req's signer) and answers 403 when it does
  not match.

  `start/1` returns `%{endpoint, bucket, access_key_id, secret_access_key, server}`.
  `fault/2` makes the next requests misbehave (`{:status, n}`, `{:delay, ms}`,
  `{:close}`), `requests/1` lists what it received, and `put_object/3`, `objects/1`,
  `age/3` inspect or change the stored objects directly.
  """

  @behaviour Plug

  def start(opts \\ []) do
    {:ok, agent} =
      Agent.start(fn ->
        %{
          objects: %{},
          faults: [],
          requests: [],
          page_size: Keyword.get(opts, :page_size, 1000),
          bucket: "rules-bucket",
          access_key_id: "AKIDFAKES3",
          secret_access_key: "fake-s3-secret-" <> Base.encode16(:crypto.strong_rand_bytes(8)),
        }
      end)

    {:ok, server} =
      Bandit.start_link(plug: {__MODULE__, agent}, port: 0, ip: :loopback, startup_log: false)

    Process.unlink(server)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    state = Agent.get(agent, & &1)

    %{
      endpoint: "http://localhost:#{port}",
      bucket: state.bucket,
      access_key_id: state.access_key_id,
      secret_access_key: state.secret_access_key,
      server: server,
      agent: agent,
    }
  end

  def stop(%{server: server, agent: agent}) do
    for pid <- [server, agent] do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc "The `Guardian.Rules.Store` for this server, with `prefix`."
  def store(s3, prefix \\ "") do
    id = s3.access_key_id
    secret = s3.secret_access_key

    {Guardian.Rules.Store.S3,
     %Guardian.Rules.Store.S3{
       endpoint: s3.endpoint,
       bucket: s3.bucket,
       region: "auto",
       prefix: prefix,
       credentials: fn -> {id, secret} end,
     }}
  end

  def fault(%{agent: agent}, faults) do
    Agent.update(agent, &%{&1 | faults: List.wrap(faults)})
  end

  def requests(%{agent: agent}) do
    Agent.get(agent, &Enum.reverse(&1.requests))
  end

  def objects(%{agent: agent}) do
    Agent.get(agent, & &1.objects)
  end

  def put_object(%{agent: agent}, key, body) do
    Agent.update(agent, fn state -> put_in(state.objects[key], object(body)) end)
  end

  @doc "Makes `key` look `seconds` older."
  def age(%{agent: agent}, key, seconds) do
    Agent.update(agent, fn state ->
      update_in(state.objects[key].modified, &(&1 - seconds))
    end)
  end

  defp object(body) do
    %{
      body: body,
      etag: Base.encode16(:crypto.hash(:md5, body), case: :lower),
      modified: System.os_time(:second),
    }
  end

  @impl true
  def init(agent) do
    agent
  end

  @impl true
  def call(conn, agent) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    state = Agent.get(agent, & &1)

    Agent.update(agent, fn state ->
      %{
        state
        | requests: [
            %{
              method: conn.method,
              path: conn.request_path,
              query: conn.query_string,
              headers: conn.req_headers,
            }
            | state.requests,
          ],
      }
    end)

    fault =
      Agent.get_and_update(agent, fn
        %{faults: [fault | rest]} = state -> {fault, %{state | faults: rest}}
        state -> {nil, state}
      end)

    conn = Plug.Conn.put_resp_header(conn, "date", http_date(System.os_time(:second)))

    case fault do
      {:delay, ms} ->
        Process.sleep(ms)
        handle(conn, agent, state, body)

      {:status, status} ->
        Plug.Conn.send_resp(conn, status, "")

      {:close} ->
        raise "closing the connection"

      nil ->
        handle(conn, agent, state, body)
    end
  end

  defp handle(conn, agent, state, body) do
    if signature_valid?(conn, body, state) do
      route(conn, agent, state, body)
    else
      Plug.Conn.send_resp(conn, 403, "<Error><Code>SignatureDoesNotMatch</Code></Error>")
    end
  end

  defp route(conn, agent, state, body) do
    bucket_path = "/" <> state.bucket

    case {conn.method, conn.request_path} do
      {"GET", ^bucket_path} ->
        list(conn, state)

      {method, "/" <> path} ->
        case String.split(path, "/", parts: 2) do
          [bucket, key] when bucket == state.bucket ->
            object(conn, agent, method, URI.decode(key), body)

          _ ->
            Plug.Conn.send_resp(conn, 404, "<Error><Code>NoSuchBucket</Code></Error>")
        end
    end
  end

  defp list(conn, state) do
    params = Plug.Conn.Query.decode(conn.query_string)
    prefix = params["prefix"] || ""
    after_key = params["continuation-token"]

    keys =
      state.objects
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()
      |> Enum.filter(&(after_key == nil or &1 > after_key))

    {page, rest} = Enum.split(keys, state.page_size)

    contents =
      Enum.map_join(page, fn key ->
        object = state.objects[key]

        "<Contents><Key>#{key}</Key><ETag>\"#{object.etag}\"</ETag><Size>#{byte_size(object.body)}</Size></Contents>"
      end)

    truncated =
      if rest == [],
        do: "<IsTruncated>false</IsTruncated>",
        else:
          "<IsTruncated>true</IsTruncated><NextContinuationToken>#{List.last(page)}</NextContinuationToken>"

    xml =
      ~s(<?xml version="1.0" encoding="UTF-8"?><ListBucketResult>#{contents}#{truncated}</ListBucketResult>)

    Plug.Conn.send_resp(conn, 200, xml)
  end

  defp object(conn, agent, method, key, body) do
    if_match = conn |> Plug.Conn.get_req_header("if-match") |> List.first()
    if_none_match = conn |> Plug.Conn.get_req_header("if-none-match") |> List.first()

    Agent.get_and_update(agent, fn state ->
      current = state.objects[key]

      precondition_ok =
        (if_match == nil or (current != nil and if_match == ~s("#{current.etag}"))) and
          (if_none_match != "*" or current == nil)

      case {method, current, precondition_ok} do
        {_, _, false} ->
          {{412, [], ""}, state}

        {"GET", nil, _} ->
          {{404, [], ""}, state}

        {"GET", current, _} ->
          {{200,
            [{"etag", ~s("#{current.etag}")}, {"last-modified", http_date(current.modified)}],
            current.body}, state}

        {"PUT", _, _} ->
          new = object(body)
          {{200, [{"etag", ~s("#{new.etag}")}], ""}, put_in(state.objects[key], new)}

        {"DELETE", _, _} ->
          {{204, [], ""}, %{state | objects: Map.delete(state.objects, key)}}
      end
    end)
    |> then(fn {status, headers, resp_body} ->
      conn |> Plug.Conn.merge_resp_headers(headers) |> Plug.Conn.send_resp(status, resp_body)
    end)
  end

  ## SigV4, independently of Req

  defp signature_valid?(conn, body, state) do
    with [authorization] <- Plug.Conn.get_req_header(conn, "authorization"),
         %{"credential" => credential, "signed" => signed, "signature" => signature} <-
           Regex.named_captures(
             ~r/^AWS4-HMAC-SHA256 Credential=(?<credential>[^,]+), ?SignedHeaders=(?<signed>[^,]+), ?Signature=(?<signature>[0-9a-f]+)$/,
             authorization
           ),
         [access_key_id, date, region, "s3", "aws4_request"] <- String.split(credential, "/"),
         true <- access_key_id == state.access_key_id,
         [amz_date] <- Plug.Conn.get_req_header(conn, "x-amz-date"),
         [payload_hash] <- Plug.Conn.get_req_header(conn, "x-amz-content-sha256"),
         true <- payload_hash == hex(:crypto.hash(:sha256, body)) do
      signed_headers = String.split(signed, ";")

      canonical_headers =
        Enum.map_join(signed_headers, fn name ->
          value = conn |> Plug.Conn.get_req_header(name) |> Enum.join(",") |> String.trim()
          "#{name}:#{value}\n"
        end)

      canonical_request =
        Enum.join(
          [
            conn.method,
            conn.request_path,
            canonical_query(conn.query_string),
            canonical_headers,
            signed,
            payload_hash,
          ],
          "\n"
        )

      scope = "#{date}/#{region}/s3/aws4_request"

      string_to_sign =
        Enum.join(
          ["AWS4-HMAC-SHA256", amz_date, scope, hex(:crypto.hash(:sha256, canonical_request))],
          "\n"
        )

      key =
        ["AWS4" <> state.secret_access_key, date, region, "s3", "aws4_request"]
        |> Enum.reduce(fn data, key -> hmac(key, data) end)

      hex(hmac(key, string_to_sign)) == signature
    else
      _ -> false
    end
  end

  defp canonical_query("") do
    ""
  end

  defp canonical_query(query) do
    query
    |> String.split("&")
    |> Enum.map(fn pair ->
      [name, value] =
        case String.split(pair, "=", parts: 2) do
          [name, value] -> [name, value]
          [name] -> [name, ""]
        end

      {encode(URI.decode_www_form(name)), encode(URI.decode_www_form(value))}
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {name, value} -> "#{name}=#{value}" end)
  end

  defp encode(text) do
    URI.encode(text, &URI.char_unreserved?/1)
  end

  defp hmac(key, data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  defp hex(binary) do
    Base.encode16(binary, case: :lower)
  end

  @months ~w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
  @days ~w[Mon Tue Wed Thu Fri Sat Sun]

  defp http_date(seconds) do
    dt = DateTime.from_unix!(seconds)
    day = Enum.at(@days, Date.day_of_week(dt) - 1)
    month = Enum.at(@months, dt.month - 1)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")

    "#{day}, #{pad.(dt.day)} #{month} #{dt.year} #{pad.(dt.hour)}:#{pad.(dt.minute)}:#{pad.(dt.second)} GMT"
  end
end

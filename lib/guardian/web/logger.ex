defmodule Guardian.Web.Logger do
  alias Plug.Conn
  require Logger

  def init(opts) do
    opts
  end

  def call(conn, _opts) do
    hostname = Guardian.Utils.hostname()
    plug_route = conn.private.plug_route |> elem(0)
    scheme = conn.scheme |> Atom.to_string()
    remote_ip = conn.remote_ip |> :inet.ntoa() |> List.to_string()
    x_forwarded_for = Plug.Conn.get_req_header(conn, "x-forwarded-for") |> List.first()
    referer = Plug.Conn.get_req_header(conn, "referer") |> List.first()
    user_agent = Plug.Conn.get_req_header(conn, "user-agent") |> List.first()
    # Where the key was found ("header" or "query"), never the key itself.
    auth_method = conn.private |> Map.get(:guardian_auth_method) |> atom_name()
    # Which key ("ingest", "admin" or "legacy"), never the key itself.
    auth_key = conn.private |> Map.get(:guardian_auth_key) |> atom_name()

    # The fields `web_requests` and `web_responses` share. Host, port, method and path
    # are read from the conn at hand: the request's, then the one being sent.
    request_fields = fn conn ->
      [
        timestamp: Guardian.Timestamp.now(),
        hostname: hostname,
        host: conn.host,
        port: conn.port,
        method: conn.method,
        path: conn.request_path,
        plug_route: plug_route,
        scheme: scheme,
        remote_ip: remote_ip,
        x_forwarded_for: x_forwarded_for,
        referer: referer,
        user_agent: user_agent,
        auth_method: auth_method,
        auth_key: auth_key,
      ]
    end

    log_event("web_requests", request_fields.(conn))

    start_time = System.monotonic_time()

    Conn.register_before_send(conn, fn conn ->
      finish_time = System.monotonic_time()
      response_time = System.convert_time_unit(finish_time - start_time, :native, :millisecond)

      log_event(
        "web_responses",
        request_fields.(conn) ++
          [
            response_time_ms: response_time,
            response_size: IO.iodata_length(conn.resp_body),
            status: conn.status,
          ]
      )

      conn
    end)
  end

  defp atom_name(nil) do
    nil
  end

  defp atom_name(atom) when is_atom(atom) do
    Atom.to_string(atom)
  end

  # A request must not fail because its log event could not be written (Storage
  # restarting, a header value that cannot be stored), so a failure is logged by kind
  # and the request goes on.
  defp log_event(table, event) do
    case Guardian.Engine.try_log_event(table, event) do
      {:ok, _event} ->
        :ok

      {:error, kind} ->
        Logger.warning("Could not record a #{table} event: #{kind}")
        :ok
    end
  end
end

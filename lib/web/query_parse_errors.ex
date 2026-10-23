defmodule Web.QueryParseErrors do
  @moduledoc """
  Records query-API parse failures in the built-in `query_parse_errors` table, so real
  failing queries can guide better parse error messages.

  `Web.Query.execute/3`, the JSON and MCP query path, hands each `AST.ParseError` to
  `record/4`, which hands one row to this GenServer; the original error is then
  reraised, so the caller's response is exactly what it would have been. The handoff
  is a cast: the request never waits on the recorder or Storage. Rows are written by
  this process, capped per machine per clock hour. Any failure to build, hand off, or
  write a row is logged with `Logger.error`, naming only the failure's kind (as
  `Engine.try_log_event/2` does, never a message or stack, which could carry query
  text), and never reaches the caller.
  """

  use GenServer

  require Logger

  @table "query_parse_errors"
  @max_sql_bytes 16 * 1024
  @max_error_bytes 1024
  @max_caller_field_bytes 256
  @default_rows_per_hour 60
  # Past this many queued rows (Storage stalled under a flood), new rows are dropped
  # before they reach the mailbox.
  @max_queue 100

  def table, do: @table
  def max_sql_bytes, do: @max_sql_bytes
  def max_caller_field_bytes, do: @max_caller_field_bytes

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Hands one parse failure to the recorder. `caller_fun` returns the caller fields
  (see `http_caller/1` and `mcp_caller/1`). Never raises, throws, or exits; always
  returns `:ok`. Options: `:server` names the recorder.
  """
  def record(sql, %AST.ParseError{} = error, caller_fun, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    caller = caller_fun.()
    row = row(sql, error, caller)

    # A cast to a dead or unregistered process succeeds silently, so check first.
    case GenServer.whereis(server) do
      nil ->
        log_failure(row["interface"], "the recorder is not running")

      pid ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} when len >= @max_queue ->
            log_failure(row["interface"], "the recorder is #{len} rows behind")

          _ ->
            GenServer.cast(pid, {:record, row})
        end
    end

    :ok
  catch
    kind, reason ->
      log_failure(nil, Engine.failure_kind(kind, reason, __STACKTRACE__))
      :ok
  end

  @doc """
  Waits until the recorder has handled everything sent to it before this call.
  """
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)

  @doc false
  def row(sql, error, caller) do
    {stored_sql, truncated?} = truncate(sql, @max_sql_bytes)
    {message, _} = truncate(Exception.message(error), @max_error_bytes)

    caller
    |> bound_caller_fields()
    |> Map.merge(%{
      "timestamp" => Timestamp.now(),
      "hostname" => Utils.hostname(),
      "sql" => stored_sql,
      "sql_bytes" => byte_size(sql),
      "sql_truncated" => truncated?,
      "error" => message,
    })
  end

  @doc """
  Bounds each caller field (see `http_caller/1` and `mcp_caller/1`) to
  #{@max_caller_field_bytes} bytes; a non-string value becomes nil.
  """
  def bound_caller_fields(caller) do
    Map.new(caller, fn {key, value} -> {key, bound_caller_field(value)} end)
  end

  defp bound_caller_field(value) when is_binary(value) do
    {value, _} = truncate(value, @max_caller_field_bytes)
    value
  end

  defp bound_caller_field(_value), do: nil

  @doc """
  Cuts `string` to at most `max_bytes` bytes without splitting a UTF-8 character.
  Returns `{string, truncated?}`. Invalid UTF-8 is cut at the byte limit.

  The result is always a fresh copy, never a sub-binary, so a queued or stored row
  does not keep a larger original (a huge request body, say) alive in memory.
  """
  def truncate(string, max_bytes) when byte_size(string) <= max_bytes do
    {:binary.copy(string), false}
  end

  def truncate(string, max_bytes) do
    {:binary.copy(utf8_prefix(binary_part(string, 0, max_bytes), 3)), true}
  end

  # Drop up to three trailing bytes of an incomplete UTF-8 character.
  defp utf8_prefix(prefix, tries) do
    if tries == 0 or prefix == "" or String.valid?(prefix) do
      prefix
    else
      utf8_prefix(binary_part(prefix, 0, byte_size(prefix) - 1), tries - 1)
    end
  end

  @doc """
  Caller fields from a Plug connection (the JSON API).
  """
  def http_caller(conn) do
    %{
      "interface" => "http",
      "remote_ip" => format_ip(conn.remote_ip),
      "x_forwarded_for" => header(conn.req_headers, "x-forwarded-for"),
      "user_agent" => header(conn.req_headers, "user-agent"),
    }
  end

  @doc """
  Caller fields from an Anubis frame (the MCP `query` tool). The client name and
  version are null when Anubis has no `clientInfo` for the session.
  """
  def mcp_caller(frame) do
    transport = frame.transport || %{}
    headers = Map.get(transport, :req_headers) || []
    client_info = Map.get(frame.private || %{}, :client_info)
    client_info = if is_map(client_info), do: client_info, else: %{}

    %{
      "interface" => "mcp",
      "remote_ip" => format_ip(Map.get(transport, :remote_ip)),
      "x_forwarded_for" => header(headers, "x-forwarded-for"),
      "user_agent" => header(headers, "user-agent"),
      "mcp_client_name" => client_info["name"],
      "mcp_client_version" => client_info["version"],
    }
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> nil
      charlist -> List.to_string(charlist)
    end
  end

  defp format_ip(_), do: nil

  # `detail` is a fixed description or a failure kind, never caller data.
  defp log_failure(interface, detail) do
    which = if interface, do: "#{interface} ", else: ""
    Logger.error("Failed to record a #{which}query parse error: #{detail}")
  end

  # Server

  @impl true
  def init(opts) do
    limit =
      Keyword.get_lazy(opts, :rows_per_hour, fn ->
        Application.get_env(:guardian, :query_parse_errors_per_hour, @default_rows_per_hour)
      end)

    clock = Keyword.get(opts, :clock, fn -> System.system_time(:second) end)
    # A writer returns like `Engine.try_log_event/2` and never raises.
    writer = Keyword.get(opts, :writer, &Engine.try_log_event/2)

    {:ok,
     %{limit: limit, clock: clock, writer: writer, hour: nil, count: 0, dropped: 0, warned: nil}}
  end

  @impl true
  def handle_cast({:record, row}, state) do
    hour = div(state.clock.(), 3600)
    state = if hour == state.hour, do: state, else: %{state | hour: hour, count: 0}

    if state.count < state.limit do
      # A write that fails still counts against the cap, and its row joins the count
      # carried to the next row that is written.
      dropped =
        case write(state.writer, Map.put(row, "dropped_before", state.dropped)) do
          :ok -> 0
          :error -> state.dropped + 1
        end

      {:noreply, %{state | count: state.count + 1, dropped: dropped}}
    else
      if state.warned != hour do
        Logger.warning(
          "query_parse_errors: #{state.limit} rows already recorded this hour on this " <>
            "machine; dropping rows until the next hour"
        )
      end

      {:noreply, %{state | dropped: state.dropped + 1, warned: hour}}
    end
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  defp write(writer, row) do
    case writer.(@table, row) do
      {:ok, _event} ->
        :ok

      {:error, kind} ->
        log_failure(row["interface"], kind)
        :error
    end
  end
end

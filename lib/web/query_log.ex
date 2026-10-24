defmodule Web.QueryLog do
  @moduledoc """
  Records every query the query APIs run in the built-in `queries` table: the JSON
  `/query` endpoint and the MCP `query` tool, each through `Web.Query.execute/3`.

  `Web.Query.execute/3` runs on the machine that received the request, which
  coordinates the query, so each query is recorded once there; peers running parts of
  it record nothing. It hands one row per query to `record/4`, which casts it to this
  GenServer: the request never waits on the recorder or Storage, so an MCP call (run
  inside Anubis's shared server process) is never held up by a stalled write. Writing
  a row is an ingest, never a query, so recording cannot cause more recording.

  Any failure to build, hand off, or write a row is logged with `Logger.error`, naming
  only the failure's kind (never query text), and never reaches the caller. Rows
  dropped for a full backlog or a failed write are counted in the next recorded row's
  `dropped_before`; rows dropped while the recorder is down are only logged.
  """

  use GenServer

  require Logger

  alias Web.QueryParseErrors

  @table "queries"
  @max_sql_bytes 16 * 1024
  @max_error_bytes 1024
  # Past this many queued rows (Storage stalled), new rows are dropped before they
  # reach the mailbox, so the backlog's memory stays bounded (at most ~17 KiB a row).
  @max_queue 1000
  # The caller fields kept. No request header is recorded (not even user agent or
  # x-forwarded-for, which `query_parse_errors` keeps): the MCP client's name and
  # version come from its `initialize` message, not a header.
  @caller_fields ~w(interface remote_ip mcp_client_name mcp_client_version)
  # Slots of the recorder's atomics: rows senders dropped for a full backlog, and
  # whether the current backlog has been logged.
  @backlog_drops 1
  @backlog_warned 2

  def table, do: @table
  def max_sql_bytes, do: @max_sql_bytes
  def max_error_bytes, do: @max_error_bytes

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Hands one query's row to the recorder. `outcome` is what the query produced:

  - `{:ok, row_count}`
  - `{:error, error_kind, message}`, where `error_kind` is `"parse"`, `"query"` or
    `"internal"` and `message` is the error text

  `info` holds `:timestamp` (when the query started), `:duration_native` (its run
  time in native time units) and `:caller_fun` (returns the caller fields, see
  `Web.QueryParseErrors.http_caller/1` and `mcp_caller/1`; only `interface`,
  `remote_ip` and the MCP client name and version are kept). Never raises, throws, or
  exits; always returns `:ok`. Options: `:server` names the recorder.
  """
  def record(sql, outcome, info, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    row = row(sql, outcome, info)

    # A cast to a dead or unregistered process succeeds silently, so check first. A
    # row dropped for a full backlog shows in the next row's `dropped_before`; one
    # dropped while the recorder is down is only logged (a restarted recorder starts
    # counting from zero).
    case GenServer.whereis(server) do
      nil ->
        log_failure("the recorder is not running")

      pid ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} when len >= @max_queue ->
            note_backlog_drop(server)

          _ ->
            GenServer.cast(pid, {:record, row})
        end
    end

    :ok
  catch
    kind, reason ->
      log_failure(Engine.failure_kind(kind, reason, __STACKTRACE__))
      :ok
  end

  @doc """
  Waits until the recorder has handled everything sent to it before this call.
  """
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)

  @doc false
  def row(sql, outcome, info) do
    {stored_sql, truncated?} = Query.Text.truncate(sql, @max_sql_bytes)

    {status, row_count, error_kind, error} =
      case outcome do
        {:ok, row_count} ->
          {"ok", row_count, nil, nil}

        {:error, kind, message} ->
          {message, _} = Query.Text.truncate(message, @max_error_bytes)
          {"error", nil, kind, message}
      end

    duration_us = System.convert_time_unit(info.duration_native, :native, :microsecond)

    info.caller_fun.()
    |> Map.take(@caller_fields)
    |> QueryParseErrors.bound_caller_fields()
    |> Map.merge(%{
      "timestamp" => info.timestamp,
      "hostname" => Utils.hostname(),
      "sql" => stored_sql,
      "sql_bytes" => byte_size(sql),
      "sql_truncated" => truncated?,
      "duration_ms" => duration_us / 1000,
      "outcome" => status,
      "row_count" => row_count,
      "error_kind" => error_kind,
      "error" => error,
    })
  end

  # `detail` is a fixed description or a failure kind, never caller data.
  defp log_failure(detail) do
    Logger.error("Failed to record a query in #{@table}: #{detail}")
  end

  # Rows dropped by senders because the backlog was full are counted in an atomic the
  # recorder owns (no message, which under a flood would grow the mailbox it guards).
  # The first drop of a backlog logs, and sets a flag the recorder clears once its
  # backlog has fallen to half the cap, so a backlog logs once however long it lasts.
  defp note_backlog_drop(server) do
    counters = :persistent_term.get({__MODULE__, server})
    :atomics.add(counters, @backlog_drops, 1)

    if :atomics.compare_exchange(counters, @backlog_warned, 0, 1) == :ok do
      log_failure("the recorder is #{@max_queue} rows behind; dropping rows until it catches up")
    end
  end

  # Server

  @impl true
  def init(opts) do
    # A writer returns like `Engine.try_log_event/2` and never raises.
    writer = Keyword.get(opts, :writer, &Engine.try_log_event/2)
    name = Keyword.fetch!(opts, :name)
    counters = :atomics.new(2, signed: false)
    :persistent_term.put({__MODULE__, name}, counters)
    # `unwritten`: rows not written since the last row that was (backlog drops already
    # taken from the atomics, and failed writes).
    {:ok, %{writer: writer, counters: counters, unwritten: 0}}
  end

  @impl true
  def handle_cast({:record, row}, state) do
    dropped = state.unwritten + :atomics.exchange(state.counters, @backlog_drops, 0)
    clear_backlog_warning(state.counters)

    case state.writer.(@table, Map.put(row, "dropped_before", dropped)) do
      {:ok, _event} ->
        {:noreply, %{state | unwritten: 0}}

      {:error, kind} ->
        log_failure(kind)
        {:noreply, %{state | unwritten: dropped + 1}}
    end
  end

  defp clear_backlog_warning(counters) do
    if :atomics.get(counters, @backlog_warned) == 1 do
      {:message_queue_len, len} = Process.info(self(), :message_queue_len)
      if len <= div(@max_queue, 2), do: :atomics.put(counters, @backlog_warned, 0)
    end
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}
end

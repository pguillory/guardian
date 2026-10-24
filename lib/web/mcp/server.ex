defmodule Web.MCP.Server do
  @moduledoc """
  MCP (Model Context Protocol) server for Guardian.

  Exposes Guardian's query and ingestion capabilities to LLM agents.

  ## Tools

  - `query` - Execute SQL queries, returns list of maps
  - `send_events` - Ingest events independently, returns ordered per-event results
  - `list_rules`, `read_rule`, `write_rule`, `delete_rule` - Manage ingest-time rules
    (`Rules`)

  ## Resources

  - `guardian://query-language` - The full query language reference (Markdown)

  ## Authentication

  Uses the same `x-api-key` header authentication as the JSON API. A valid key grants
  access to the whole event store; no identity is attached.
  """

  use Anubis.Server,
    name: "guardian",
    version: "0.1.0",
    capabilities: [:tools, :resources]

  alias Anubis.Server.Response

  @query_language_uri "guardian://query-language"
  @query_language_path Path.join(__DIR__, "query_language.md")
  @external_resource @query_language_path
  @query_language File.read!(@query_language_path)

  @query_description """
  Guardian is a schemaless event store: tables of JSON events, queried with a \
  SQL-like language. Runs one read-only statement: SHOW TABLES, DESC <table>, or \
  SELECT ... [FROM table] [WHERE] [GROUP BY] [HAVING] [ORDER BY ... ASC|DESC] [LIMIT n]. \
  Supports aggregates (count(), sum, avg, min, max, count_distinct, ...), scalar \
  functions (lower, concat, date_sub, type, replace, ...), CASE, BETWEEN, LIKE, and \
  IN with a bracket list: x IN ['a', 'b']. Not supported: UNION, JOIN, subqueries, \
  DISTINCT (use GROUP BY or count_distinct), OFFSET. Columns are untyped: one column \
  can hold mixed values, including lists. Nested objects are flattened into dotted \
  columns (user.name; users..name for a list of objects). A missing column is null. \
  Timestamps are plain strings, UTC by convention (not enforced), formatted \
  'YYYY-MM-DD HH:MM:SS', so when values share that format, string comparison and \
  sorting are chronological. Time arithmetic accepts only that UTC format, without \
  offsets, T, Z or fractional seconds; other formats return null. Examples: \
  SELECT status, count() FROM web_responses WHERE timestamp >= '2026-10-01 00:00:00' \
  GROUP BY status ORDER BY count() DESC LIMIT 10; \
  SELECT path FROM web_requests WHERE timestamp > date_sub(now(), INTERVAL 1 HOUR) LIMIT 20. \
  Full reference: the MCP resource #{@query_language_uri}.\
  """

  @write_rule_description """
  Create or replace a rule file, <table>/<name>.gsql. Rules run on every event sent \
  to that table through send_events, before it is stored. A file holds statements \
  separated by semicolons, with -- comments: SET field = expr [WHERE cond] sets a \
  top-level field (replacing it whole; the name is stored lowercased), UNSET path [WHERE cond] removes a field and \
  everything beneath it. Expressions are the query language's scalar expressions \
  (no aggregates). Missing fields are null; names match ignoring case. Every SET runs \
  before every UNSET; a SET that reads another SET's field runs after it. Example: \
  SET is_blocked = true WHERE signal > 0.9; UNSET password. The whole rule set is \
  validated together: a write is refused if it adds a parse error, a field defined \
  two different ways on one table, or a cycle. Ask send_events for computed fields \
  with return_keys.\
  """

  # Anubis 0.16 keeps tools and resources registered at runtime in the private map of
  # its one shared frame, and empties that map when the session it served last ends
  # (a client's DELETE). Registering them in init/2, which runs only on a client's
  # notifications/initialized, left every other session with "Tool not found" until
  # some client re-initialized. So they are registered on the frame before every
  # request; registration is idempotent (Anubis dedups by type and name).
  # Recheck on an Anubis upgrade.
  defp register_components(frame) do
    frame
    |> register_tool("query",
      description: @query_description,
      input_schema: %{
        sql: {:required, :string, description: "The SQL query to execute"},
      }
    )
    |> register_tool("send_events",
      description:
        "Ingest JSON events into a table, returning {status: 200, results: [...]} with one ordered success/event or failure/error per input. Failures do not stop later events; an error may say the event may have been stored. Optional idempotency_key suppresses matching retries on this node for 10 seconds after completion, returning {status: 200, duplicate: true, failed_events: N} without results. Protection can be lost on eviction, overload or restart; retries on another node are not protected. Changed requests, pending requests and unknown outcomes are tool errors. MCP calls can queue behind an earlier call. Table names must match [a-z_][a-z0-9_]*, be at most 64 characters, and exclude SQL keywords, null, true, false, current_date, current_timestamp, and schema. Use stable field names: put data in values, not object keys (for example, {customer_id: 123}, not {123: true}).",
      input_schema: %{
        table: {:required, :string, description: "Destination table name"},
        events: {:required, {:list, {:map, :any}}, description: "JSON event objects to ingest"},
        return_keys:
          {{:oneof, [{:list, :string}, {:literal, nil}]},
           description:
             "Fields to return for successful events; omitted or null returns all, [] returns none"},
        idempotency_key:
          {{:oneof, [:string, {:literal, nil}]},
           description:
             "Optional retry key: 1–128 UTF-8 bytes, scoped to this table on this node; reuse only with identical events and return_keys"},
      }
    )
    |> register_tool("list_rules",
      description:
        "List ingest-time rule files: each file's table, name and size in bytes. Optional table limits the list to one table.",
      input_schema: %{
        table: {:string, description: "Only this table's rule files"},
      }
    )
    |> register_tool("read_rule",
      description: "Read one rule file's source.",
      input_schema: %{
        table: {:required, :string, description: "The table the rules apply to"},
        name: {:required, :string, description: "The rule file's name, without .gsql"},
      }
    )
    |> register_tool("write_rule",
      description: @write_rule_description,
      input_schema: %{
        table: {:required, :string, description: "The table the rules apply to"},
        name:
          {:required, :string,
           description: "The rule file's name: [a-z0-9_][a-z0-9_-]*, at most 64 bytes"},
        source: {:required, :string, description: "The file's statements"},
      }
    )
    |> register_tool("delete_rule",
      description:
        "Delete one rule file. Deleting is refused if it would leave a new validation error.",
      input_schema: %{
        table: {:required, :string, description: "The table the rules apply to"},
        name: {:required, :string, description: "The rule file's name, without .gsql"},
      }
    )
    |> register_resource(@query_language_uri,
      name: "query-language",
      title: "Guardian query language",
      description: "Full syntax reference for the query tool",
      mime_type: "text/markdown"
    )
  end

  @impl true
  def handle_resource_read(@query_language_uri, frame) do
    {:reply, Response.resource() |> Response.text(@query_language), frame}
  end

  # Anubis's default schema validation returns protocol errors and rejects whole
  # mixed batches. Validate this tool explicitly so events reach Engine unchanged
  # and invalid requests return tool errors. Other tools keep the default path.
  @impl true
  def handle_request(
        %{"method" => "tools/call", "params" => %{"name" => "send_events"} = params},
        frame
      ) do
    frame = register_components(frame)

    {:reply, response, frame} =
      handle_tool_call("send_events", Map.get(params, "arguments", %{}), frame)

    {:reply, Response.to_protocol(response), frame}
  end

  # Every other request: the dispatch Anubis 0.16's own default handle_request/2 does
  # (it is appended after these clauses at compile time, so `super` is unavailable).
  # Matching on "method" keeps that appended `%{}` clause reachable, so no warning.
  def handle_request(%{"method" => _} = request, frame) do
    Anubis.Server.Handlers.handle(request, __MODULE__, register_components(frame))
  end

  @impl true
  def handle_tool_call("send_events", params, frame) do
    response =
      case Web.Ingest.send_events(params) do
        {:ok, result} -> Response.tool() |> Response.json(result)
        {:error, message} -> Response.tool() |> Response.error(message)
        {:error, _status, message} -> Response.tool() |> Response.error(message)
      end

    {:reply, response, frame}
  end

  def handle_tool_call("list_rules", params, frame) do
    reply(frame, Rules.list_rules(Map.get(params, :table)))
  end

  def handle_tool_call("read_rule", %{table: table, name: name}, frame) do
    case Rules.read_rule(table, name) do
      {:ok, source} -> reply(frame, {:ok, %{table: table, name: name, source: source}})
      error -> reply(frame, error)
    end
  end

  def handle_tool_call("write_rule", %{table: table, name: name, source: source}, frame) do
    reply(frame, rule_write_result(Rules.write_rule(table, name, source)))
  end

  def handle_tool_call("delete_rule", %{table: table, name: name}, frame) do
    reply(frame, rule_write_result(Rules.delete_rule(table, name)))
  end

  def handle_tool_call("query", %{sql: sql}, frame) do
    try do
      # Every query is recorded in queries; parse failures also in query_parse_errors,
      # and reraised unchanged.
      case Web.Query.execute(sql, fn -> Web.QueryParseErrors.mcp_caller(frame) end) do
        {:ok, columns, rows} ->
          result =
            Enum.map(rows, fn row ->
              columns
              |> Enum.zip(row)
              |> Map.new()
            end)

          response = Response.tool() |> Response.json(result)
          {:reply, response, frame}

        {:error, message} ->
          response = Response.tool() |> Response.error(message)
          {:reply, response, frame}
      end
    rescue
      e ->
        response = Response.tool() |> Response.error(Exception.message(e))
        {:reply, response, frame}
    end
  end

  defp reply(frame, {:ok, result}), do: {:reply, Response.tool() |> Response.json(result), frame}

  defp reply(frame, {:error, message}),
    do: {:reply, Response.tool() |> Response.error(message), frame}

  defp rule_write_result({:ok, %{errors: errors, unconfirmed: unconfirmed}}) do
    {:ok,
     %{
       saved: true,
       remaining_errors: errors,
       nodes_not_yet_reloaded: Enum.map(unconfirmed, &to_string/1),
     }}
  end

  defp rule_write_result({:error, {:rejected, messages}}),
    do: {:error, "rejected; nothing was saved:\n" <> Enum.join(messages, "\n")}

  defp rule_write_result({:error, {:unknown, message}}), do: {:error, message}
  defp rule_write_result({:error, message}), do: {:error, message}
end

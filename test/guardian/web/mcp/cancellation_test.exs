defmodule Guardian.Web.MCP.CancellationTest do
  # Anubis 2.x stops a request's task when the client cancels the request
  # (notifications/cancelled) or deletes its session. A query stops with it, freeing the
  # machine for a client that gave up. Ingestion does not: send_events runs in a
  # detached process (Guardian.Detached), so a batch is never half-stored and a keyed
  # receipt still completes.
  #
  # Each test holds the work in progress by suspending the table's one mutable segment,
  # which schema lookups and every append call. Segment.append uses GenServer.call's
  # default 5-second timeout, so the send_events tests resume the segment promptly,
  # with no sleeps in between: only requests that do not touch the segment.
  use ExUnit.Case, async: false

  alias Guardian.Storage.MutableSegments
  alias Guardian.Test.MCPHTTP

  @wait 5_000

  setup do
    table = "mcp_cancel_#{System.unique_integer([:positive])}"
    Guardian.Engine.ingest_event(table, %{"n" => 0})
    assert [segment] = MutableSegments.get_mutable_segments(table)
    on_exit(fn -> if Process.alive?(segment), do: :sys.resume(segment) end)
    %{table: table, segment: segment}
  end

  # Waits until a call is queued at the suspended segment and returns its caller.
  defp blocked_caller(segment) do
    Guardian.Test.Processes.await_queued_call(segment)
    {:messages, [{:"$gen_call", {caller, _}, _} | _]} = Process.info(segment, :messages)
    caller
  end

  # The schema lookup's erpc worker is monitored by the process that asked: the query
  # process, which is not the request's task (a Task has $callers).
  defp query_process(erpc_worker) do
    {:monitored_by, [query]} = Process.info(erpc_worker, :monitored_by)
    {:dictionary, dictionary} = Process.info(query, :dictionary)
    refute Keyword.has_key?(dictionary, :"$callers")
    query
  end

  defp count(table) do
    {:ok, _labels, [[count]]} = Guardian.Query.execute("SELECT count() FROM #{table}", [])
    count
  end

  defp assert_mcp_error(conn, id, message) do
    assert conn.status == 200
    assert %{"id" => ^id, "error" => %{"message" => _} = error} = Jason.decode!(conn.resp_body)
    assert inspect(error) =~ message
  end

  for how <- [:delete, :cancel] do
    test "a running query stops when its request is stopped (#{how})", %{
      table: table,
      segment: segment,
    } do
      session_id = MCPHTTP.open_session()
      :sys.suspend(segment)

      # DESC looks up the schema inside the query process (a SELECT resolves it first,
      # in the request), so the query is running when it blocks on the segment.
      request =
        Task.async(fn ->
          MCPHTTP.call_tool(session_id, 7, "query", %{"sql" => "DESC #{table}"})
        end)

      query = query_process(blocked_caller(segment))
      query_ref = Process.monitor(query)

      case unquote(how) do
        :delete ->
          assert MCPHTTP.request(:delete, nil, MCPHTTP.session(session_id)).status == 200
          assert_mcp_error(Task.await(request, @wait), 7, "Session terminating")

        :cancel ->
          assert MCPHTTP.cancel(session_id, 7).status == 202
          assert_mcp_error(Task.await(request, @wait), 7, "Request cancelled")
      end

      # Killed with the request, well before the segment call's own 5-second timeout
      # would have let it go on.
      assert_receive {:DOWN, ^query_ref, :process, ^query, :killed}, 1_000
      :sys.resume(segment)

      other = MCPHTTP.open_session()
      sql = "SELECT count() AS c FROM #{table}"

      assert MCPHTTP.tool_json!(MCPHTTP.call_tool(other, 8, "query", %{"sql" => sql}), 8) == [
               %{"c" => 1},
             ]
    end

    test "send_events stores its whole batch when its request is stopped (#{how})", %{
      table: table,
      segment: segment,
    } do
      session_id = MCPHTTP.open_session()
      key = "cancel-#{unquote(how)}"
      events = [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]
      arguments = %{"table" => table, "events" => events, "idempotency_key" => key}
      :sys.suspend(segment)

      request = Task.async(fn -> MCPHTTP.call_tool(session_id, 9, "send_events", arguments) end)
      _worker = blocked_caller(segment)

      case unquote(how) do
        :delete ->
          assert MCPHTTP.request(:delete, nil, MCPHTTP.session(session_id)).status == 200
          assert_mcp_error(Task.await(request, @wait), 9, "Session terminating")

        :cancel ->
          assert MCPHTTP.cancel(session_id, 9).status == 202
          assert_mcp_error(Task.await(request, @wait), 9, "Request cancelled")
      end

      # While the write is still held: the session (if it still exists) serves its next
      # request, and a same-key retry is told the first is still in flight.
      if unquote(how) == :cancel do
        one = MCPHTTP.call_tool(session_id, 11, "query", %{"sql" => "SELECT 1 AS one"})
        assert MCPHTTP.tool_json!(one, 11) == [%{"one" => 1}]
      end

      other = MCPHTTP.open_session()
      pending = MCPHTTP.call_tool(other, 12, "send_events", arguments)
      assert %{"result" => %{"isError" => true} = result} = Jason.decode!(pending.resp_body)
      assert inspect(result) =~ "still in flight"

      :sys.resume(segment)
      Guardian.Test.Polling.eventually(fn -> count(table) == 4 end)

      # The receipt completed: a retry with the same key is a duplicate, not an
      # unknown outcome.
      assert MCPHTTP.tool_json!(MCPHTTP.call_tool(other, 10, "send_events", arguments), 10) == %{
               "status" => 200,
               "duplicate" => true,
               "failed_events" => 0,
             }

      assert count(table) == 4
    end
  end
end

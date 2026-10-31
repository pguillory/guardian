defmodule Guardian.Web.MCP.ConcurrencyTest do
  # MCP sessions do not wait for each other: Anubis 2.x runs each session in its own
  # process and each request in its own task. Under Anubis 0.16 every MCP request on a
  # machine ran in one shared process, so one slow query held up every other session.
  #
  # A telemetry handler on Anubis's tool-call start (which runs in the request's task,
  # before the tool does) holds `query` calls from this test's sessions until the test
  # releases them, so "slow" is deterministic. The handler is global, but it only holds
  # tasks started by the sessions a test registers, so the module can run async.
  use ExUnit.Case, async: true

  alias Guardian.Test.MCPHTTP

  @event [:anubis_mcp, :server, :tool_call, :start]
  @wait 5_000

  setup do
    handler = "mcp-concurrency-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler) end)
    %{handler: handler}
  end

  # Holds this test's query calls: each reports {:entered, task, session} and waits for
  # :release, or for the test process to exit, so a failed test never leaves a task
  # stuck (10 s at most in any case).
  defp hold_queries(handler, session_ids) do
    sessions = Map.new(session_ids, &{MCPHTTP.session_pid(&1), &1})
    test = self()

    :ok =
      :telemetry.attach(handler, @event, &__MODULE__.handle_start/4, %{
        test: test,
        sessions: sessions,
      })
  end

  @doc false
  def handle_start(_event, _measurements, %{tool: "query"}, config) do
    # A Task's $callers names the process that started it: here, the session.
    with [session | _] <- Process.get(:"$callers", []),
         {:ok, session_id} <- Map.fetch(config.sessions, session) do
      test = Process.monitor(config.test)
      send(config.test, {:entered, self(), session_id})

      receive do
        :release -> :ok
        {:DOWN, ^test, :process, _, _} -> :ok
      after
        10_000 -> :ok
      end
    end

    :ok
  end

  def handle_start(_event, _measurements, _metadata, _config) do
    :ok
  end

  defp query_async(session_id, id) do
    Task.async(fn ->
      MCPHTTP.call_tool(session_id, id, "query", %{"sql" => "SELECT #{id} AS n"})
    end)
  end

  test "slow queries on two sessions run at the same time", %{handler: handler} do
    a = MCPHTTP.open_session()
    b = MCPHTTP.open_session()
    hold_queries(handler, [a, b])

    query_a = query_async(a, 11)
    query_b = query_async(b, 12)

    # Both are in their tools at once: neither waits for the other to finish.
    assert_receive {:entered, task_a, ^a}, @wait
    assert_receive {:entered, task_b, ^b}, @wait

    send(task_a, :release)
    send(task_b, :release)
    assert MCPHTTP.tool_json!(Task.await(query_a, @wait), 11) == [%{"n" => 11}]
    assert MCPHTTP.tool_json!(Task.await(query_b, @wait), 12) == [%{"n" => 12}]
  end

  test "a new session initializes while another session's query is running", %{
    handler: handler,
  } do
    a = MCPHTTP.open_session()
    hold_queries(handler, [a])
    query_a = query_async(a, 21)
    assert_receive {:entered, task_a, ^a}, @wait

    # A new client's first steps (initialize, initialized), then a query of its own.
    b = Task.await(Task.async(fn -> MCPHTTP.open_session() end), @wait)

    assert MCPHTTP.tool_json!(MCPHTTP.call_tool(b, 22, "query", %{"sql" => "SELECT 22 AS n"}), 22) ==
             [%{"n" => 22}]

    send(task_a, :release)
    assert MCPHTTP.tool_json!(Task.await(query_a, @wait), 21) == [%{"n" => 21}]
  end

  test "requests on one session still run one at a time", %{handler: handler} do
    a = MCPHTTP.open_session()
    hold_queries(handler, [a])

    first = query_async(a, 31)
    assert_receive {:entered, task_1, ^a}, @wait
    second = query_async(a, 32)

    # The second waits behind the first, in the same session.
    refute_receive {:entered, _, ^a}, 300

    send(task_1, :release)
    assert MCPHTTP.tool_json!(Task.await(first, @wait), 31) == [%{"n" => 31}]
    assert_receive {:entered, task_2, ^a}, @wait
    send(task_2, :release)
    assert MCPHTTP.tool_json!(Task.await(second, @wait), 32) == [%{"n" => 32}]
  end
end

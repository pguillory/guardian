defmodule Guardian.Web.MCP.AppViewTest do
  # The query tool's MCP App view on the wire: what a client that declares the MCP Apps
  # extension gets, and that every other client gets exactly what it got before.
  use ExUnit.Case, async: true

  alias Guardian.Test.MCPHTTP
  alias Guardian.Web.MCP.ResultsView

  @apps %{
    "extensions" => %{
      "io.modelcontextprotocol/ui" => %{"mimeTypes" => ["text/html;profile=mcp-app"]},
    },
  }

  defp rpc!(session_id, id, method, params \\ %{}) do
    conn =
      MCPHTTP.request(
        :post,
        %{jsonrpc: "2.0", id: id, method: method, params: params},
        MCPHTTP.session(session_id)
      )

    assert conn.status == 200
    assert %{"id" => ^id} = body = Jason.decode!(conn.resp_body)
    body
  end

  defp query!(session_id, id, sql) do
    %{"result" => result} =
      rpc!(session_id, id, "tools/call", %{name: "query", arguments: %{sql: sql}})

    result
  end

  defp tools(session_id) do
    %{"result" => %{"tools" => tools}} = rpc!(session_id, 2, "tools/list")
    tools
  end

  defp resource_uris(session_id) do
    %{"result" => %{"resources" => resources}} = rpc!(session_id, 3, "resources/list")
    Enum.map(resources, & &1["uri"])
  end

  @sql "SELECT 'a<b' AS text, null AS missing, 2 AS n"

  test "an App host gets the view: tool metadata, the resource, and each result's HTML" do
    session_id = MCPHTTP.open_session("app-host", @apps)
    tools = tools(session_id)

    # Every tool is the model's only, so a host refuses calls from the view.
    for tool <- tools do
      expected =
        if tool["name"] == "query" do
          %{"ui" => %{"resourceUri" => "ui://guardian/query-results", "visibility" => ["model"]}}
        else
          %{"ui" => %{"visibility" => ["model"]}}
        end

      assert tool["_meta"] == expected
    end

    assert "ui://guardian/query-results" in resource_uris(session_id)

    %{"result" => %{"contents" => [contents]}} =
      rpc!(session_id, 4, "resources/read", %{uri: "ui://guardian/query-results"})

    assert contents == %{
             "uri" => "ui://guardian/query-results",
             "mimeType" => "text/html;profile=mcp-app",
             "text" => ResultsView.shell(),
             "_meta" => %{"ui" => %{"prefersBorder" => true}},
           }

    result = query!(session_id, 5, @sql)
    assert %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]} = result
    assert Jason.decode!(text) == [%{"text" => "a<b", "missing" => nil, "n" => 2}]

    assert result["_meta"] == %{
             "guardian/html" =>
               ResultsView.fragment(@sql, ["text", "missing", "n"], [["a<b", nil, 2]]),
           }

    error = query!(session_id, 6, "SELEC")
    assert %{"isError" => true, "content" => [%{"type" => "text", "text" => message}]} = error
    assert error["_meta"] == %{"guardian/html" => ResultsView.error_fragment("SELEC", message)}
  end

  test "the model gets the whole result, however much of it the view shows" do
    session_id = MCPHTTP.open_session("app-host-large", @apps)
    table = Guardian.Test.Tables.unique_table("app_view")
    long = String.duplicate("v", 1_500)
    events = for n <- 1..301, do: %{"n" => n, "v" => long}

    %{"result" => %{"isError" => false}} =
      rpc!(session_id, 2, "tools/call", %{
        name: "send_events",
        arguments: %{table: table, events: events, return_keys: []},
      })

    sql = "SELECT n, v FROM #{table} ORDER BY n"
    result = query!(session_id, 3, sql)
    assert %{"content" => [%{"text" => text}], "_meta" => %{"guardian/html" => html}} = result
    assert Jason.decode!(text) == Enum.map(events, &Map.take(&1, ["n", "v"]))
    refute html =~ long
    assert html =~ ~r/Showing \d+ of 301 rows; the full result went to the model/
  end

  test "any other client sees no view, and the same results as before" do
    plain = MCPHTTP.open_session("plain")

    other_types =
      MCPHTTP.open_session(
        "other-types",
        put_in(@apps, ["extensions", "io.modelcontextprotocol/ui"], %{
          "mimeTypes" => ["text/plain"],
        })
      )

    malformed =
      for settings <- [%{}, %{"mimeTypes" => nil}, %{"mimeTypes" => "text/html;profile=mcp-app"}] do
        MCPHTTP.open_session(
          "malformed",
          put_in(@apps, ["extensions", "io.modelcontextprotocol/ui"], settings)
        )
      end

    for session_id <- [plain, other_types | malformed] do
      refute Enum.any?(tools(session_id), &Map.has_key?(&1, "_meta"))
      assert resource_uris(session_id) == ["guardian://query-language"]

      assert %{"error" => _} =
               rpc!(session_id, 4, "resources/read", %{uri: "ui://guardian/query-results"})

      assert %{"content" => [%{"type" => "text", "text" => text}], "isError" => false} =
               result = query!(session_id, 5, @sql)

      assert Map.keys(result) == ["content", "isError"]
      assert Jason.decode!(text) == [%{"text" => "a<b", "missing" => nil, "n" => 2}]
      assert Map.keys(query!(session_id, 6, "SELEC")) == ["content", "isError"]
    end
  end
end

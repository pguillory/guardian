defmodule Web.LoggerTest do
  # Not async: it stops and restarts a Storage child.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @api_key Application.compile_env!(:guardian, :api_key)

  test "a request succeeds when its log events cannot be written" do
    log =
      capture_log(fn ->
        :ok = Supervisor.terminate_child(Storage, Storage.MutableSegments)
        on_exit(fn -> Supervisor.restart_child(Storage, Storage.MutableSegments) end)

        conn =
          Plug.Test.conn(:post, "https://localhost/api/json/query", ~s({"query": "SELECT 1"}))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("x-api-key", @api_key)
          |> Web.MainRouter.call(nil)

        assert conn.status == 200
        assert Jason.decode!(conn.resp_body)["rows"] == [[1]]
        {:ok, _pid} = Supervisor.restart_child(Storage, Storage.MutableSegments)
      end)

    assert log =~ "Could not record a web_requests event: ArgumentError"
    assert log =~ "Could not record a web_responses event: ArgumentError"
  end

  @shared_fields ~w(timestamp hostname host port method path plug_route scheme remote_ip
                    x_forwarded_for referer user_agent auth_method)

  defp logged(table, user_agent) do
    {:ok, labels, rows} =
      Query.execute("SELECT * FROM #{table} WHERE user_agent = '#{user_agent}'")

    Enum.map(rows, &(Enum.zip(labels, &1) |> Map.new()))
  end

  test "each request writes one web_requests and one web_responses row sharing its fields" do
    user_agent = "logger-test-#{System.unique_integer([:positive])}"

    conn =
      Plug.Test.conn(:post, "https://localhost/api/json/query", ~s({"query": "SELECT 1"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", @api_key)
      |> Plug.Conn.put_req_header("user-agent", user_agent)
      |> Plug.Conn.put_req_header("referer", "https://example.com/page")
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.7")
      |> Web.MainRouter.call(nil)

    assert conn.status == 200

    [request] = logged("web_requests", user_agent)
    [response] = logged("web_responses", user_agent)

    present = @shared_fields

    assert request |> Map.reject(fn {_, v} -> is_nil(v) end) |> Map.keys() |> Enum.sort() ==
             Enum.sort(present)

    assert response |> Map.reject(fn {_, v} -> is_nil(v) end) |> Map.keys() |> Enum.sort() ==
             Enum.sort(present ++ ~w(response_time_ms response_size status))

    assert Map.drop(request, ["timestamp"]) |> Map.take(@shared_fields) ==
             Map.drop(response, ["timestamp"]) |> Map.take(@shared_fields)

    assert %{
             "method" => "POST",
             "path" => "/api/json/query",
             "plug_route" => "/api/json/*glob/query",
           } =
             request

    assert %{"status" => 200, "scheme" => "https", "host" => "localhost", "port" => 443} =
             response

    assert %{"referer" => "https://example.com/page", "x_forwarded_for" => "203.0.113.7"} =
             response
  end
end

defmodule Guardian.Web.LoggerTest do
  # Not async: reads the shared web_requests and web_responses system tables.
  use ExUnit.Case, async: false

  @api_key Application.compile_env!(:guardian, :admin_api_key)

  # A valid send_events body that stores nothing.
  @empty_batch ~s({"table": "logger_test", "events": []})

  @shared_fields ~w(timestamp hostname host port method path plug_route scheme remote_ip
                    x_forwarded_for referer user_agent auth_key)

  defp logged(table, user_agent) do
    {:ok, labels, rows} =
      Guardian.Query.execute("SELECT * FROM #{table} WHERE user_agent = '#{user_agent}'")

    Enum.map(rows, &(Enum.zip(labels, &1) |> Map.new()))
  end

  test "each request writes one web_requests and one web_responses row sharing its fields" do
    user_agent = "logger-test-#{System.unique_integer([:positive])}"

    conn =
      Plug.Test.conn(:post, "https://localhost/api/json/send_events", @empty_batch)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", @api_key)
      |> Plug.Conn.put_req_header("user-agent", user_agent)
      |> Plug.Conn.put_req_header("referer", "https://example.com/page")
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.7")
      |> Guardian.Web.MainRouter.call(nil)

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
             "path" => "/api/json/send_events",
             "plug_route" => "/api/json/*glob/send_events",
             "auth_key" => "admin",
           } =
             request

    assert %{"status" => 200, "scheme" => "https", "host" => "localhost", "port" => 443} =
             response

    assert %{"referer" => "https://example.com/page", "x_forwarded_for" => "203.0.113.7"} =
             response
  end
end

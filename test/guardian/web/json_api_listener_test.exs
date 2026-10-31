defmodule Guardian.Web.JsonApiListenerTest do
  # The JSON API on the real HTTP listener (Bandit), for what Plug.Test can't send: a
  # chunked body and a body split after an Expect: 100-continue.
  use ExUnit.Case, async: true
  import Guardian.Test.Tables, only: [unique_table: 1]

  @admin_api_key Application.compile_env!(:guardian, :admin_api_key)

  test "the real HTTP listener accepts a JSON batch sent as one-byte chunks" do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Guardian.Web.bound_port(), [:binary, active: false], 2000)

    on_exit(fn -> :gen_tcp.close(socket) end)
    table = unique_table("json_chunked")
    body = Jason.encode!(%{table: table, events: [%{"x" => 1}], return_keys: ["x"]})
    chunks = for <<byte <- body>>, do: ["1\r\n", <<byte>>, "\r\n"]

    :ok =
      :gen_tcp.send(socket, [
        "POST /api/json/send_events HTTP/1.1\r\nHost: localhost\r\n",
        "x-api-key: ",
        @admin_api_key,
        "\r\nContent-Type: application/json\r\n",
        "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
        chunks,
        "0\r\n\r\n",
      ])

    response = receive_until_closed(socket, "")
    [headers, response_body] = String.split(response, "\r\n\r\n", parts: 2)
    assert headers =~ "HTTP/1.1 200 OK\r\n"

    assert Jason.decode!(response_body) == %{
             "status" => 200,
             "results" => [%{"success" => true, "event" => %{"x" => 1}}],
           }
  end

  test "a split malformed body with Expect closes promptly on the real HTTP listener" do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Guardian.Web.bound_port(), [:binary, active: false], 2000)

    on_exit(fn -> :gen_tcp.close(socket) end)
    body = "[" <> String.duplicate(" ", 70_000) <> "x"

    :ok =
      :gen_tcp.send(socket, [
        "POST /api/json/send_events HTTP/1.1\r\nHost: localhost\r\n",
        "x-api-key: ",
        @admin_api_key,
        "\r\nContent-Type: application/json\r\n",
        "Content-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n",
        "Expect: 100-continue\r\n\r\n",
      ])

    # The interim response proves Bandit consumed the headers before any body bytes
    # arrived. A direct boundary test in Guardian.Web.JsonApiTest pins our close header:
    # Bandit also closes a stale adapter with an unhonored Expect flag.
    assert receive_headers(socket, "") =~ "HTTP/1.1 100 Continue\r\n"
    :ok = :gen_tcp.send(socket, body)
    response = receive_until_closed(socket, "")
    assert response =~ "HTTP/1.1 400 Bad Request"
    assert response =~ "connection: close"
    assert response =~ "malformed JSON body"
  end

  defp receive_headers(socket, acc) do
    if String.ends_with?(acc, "\r\n\r\n") do
      acc
    else
      assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
      receive_headers(socket, acc <> bytes)
    end
  end

  defp receive_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, bytes} -> receive_until_closed(socket, acc <> bytes)
      {:error, :closed} -> acc
      other -> flunk("expected the HTTP connection to close, got #{inspect(other)}")
    end
  end
end

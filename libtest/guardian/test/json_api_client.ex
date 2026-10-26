defmodule Guardian.Test.JsonApiClient do
  @moduledoc """
  Drives Guardian's JSON API in process through `Guardian.Web.MainRouter`, the way an
  authenticated HTTP client would.
  """

  @api_key Application.compile_env!(:guardian, :api_key)

  @doc """
  Posts `sql` to `/api/json/query` with the configured API key and any extra
  request `headers`, and returns `{status, decoded_body}`.
  """
  def query(sql, headers \\ []) do
    conn =
      Plug.Test.conn(:post, "https://localhost/api/json/query", Jason.encode!(%{query: sql}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", @api_key)

    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)

    conn = Guardian.Web.MainRouter.call(conn, nil)
    {conn.status, Jason.decode!(conn.resp_body)}
  end
end

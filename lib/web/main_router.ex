defmodule Web.MainRouter do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  # Unauthenticated health check for the platform (Fly.io HTTP check). At boot the
  # listener starts only after Storage has loaded; after that, a Storage restart (which
  # leaves this listener running) answers 503 until Storage has started again. Reveals
  # only that, and reads no data.
  get "/health" do
    if Storage.ready?() do
      send_resp(conn, 200, "ok")
    else
      send_resp(conn, 503, "storage unavailable")
    end
  end

  forward("/api/json", to: Web.JsonApi)
  forward("/mcp", to: Web.MCP.Router)

  match _ do
    send_resp(conn, 404, "Not found")
  end
end

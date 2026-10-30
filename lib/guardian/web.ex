defmodule Guardian.Web do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Before Anubis starts, so none of its lines carry an MCP request.
    :ok = Guardian.Web.MCP.LogFilter.install()

    http_opts = [
      plug: Guardian.Web.MainRouter,
      port: http_port(),
    ]

    # Anubis starts its own session registry and supervisors under the server's
    # child. `start: true` serves MCP whatever Phoenix-specific environment variables
    # say (Anubis otherwise guesses from PHX_SERVER and :phoenix config).
    children = [
      {Guardian.Web.MCP.Server, transport: {:streamable_http, start: true}},
      %{
        id: Bandit.HTTP,
        start: {Bandit, :start_link, [http_opts]},
        type: :worker,
        restart: :permanent,
        shutdown: 500,
      },
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  The HTTP port: `:guardian, :http_port` (set from `GUARDIAN_PORT` by
  config/runtime.exs), else 8080.
  """
  def http_port do
    case unquote(Mix.env()) do
      # Port 0 asks the OS for a free port, so parallel test runs (other worktrees,
      # pre-commit hooks) never collide. Tests find it with `bound_port/0`.
      :test -> 0
      _ -> Application.get_env(:guardian, :http_port, 8080)
    end
  end

  @doc """
  Returns the TCP port the HTTP listener is actually bound to.
  """
  def bound_port do
    {Bandit.HTTP, pid, _, _} =
      __MODULE__
      |> Supervisor.which_children()
      |> List.keyfind(Bandit.HTTP, 0)

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end
end

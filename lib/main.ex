defmodule Main do
  use Application

  def start(_type, _args) do
    IO.puts("Starting build #{Build.commit()} built at #{Build.timestamp()}")

    children = [
      Storage,
      SystemStats,
      Web.QueryParseErrors,
      Web.QueryLog,
      Web,
      Cluster.discovery_child_spec(),
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end

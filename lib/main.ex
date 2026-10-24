defmodule Main do
  use Application

  def start(_type, _args) do
    IO.puts("Starting build #{Build.commit()} built at #{Build.timestamp()}")

    # Rules first: it loads the rule store, so a bad store refuses startup in seconds
    # rather than after Storage has loaded every segment.
    children = [
      Rules.Server,
      Counters.Restarter,
      Storage,
      SystemStats,
      Web.QueryParseErrors,
      Web.QueryLog,
      Web.IngestIdempotency,
      Web,
      Cluster.discovery_child_spec(),
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end

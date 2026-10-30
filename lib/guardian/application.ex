defmodule Guardian.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info(
      "Guardian: starting build #{Guardian.Build.commit()} built at #{Guardian.Build.timestamp()}"
    )

    # Rules first: it loads the rule store, so a bad store refuses startup in seconds
    # rather than after Storage has loaded every segment.
    children = [
      Guardian.Rules.Server,
      Guardian.Counters.Restarter,
      Guardian.Storage,
      Guardian.SystemStats,
      Guardian.Web.QueryParseErrors,
      Guardian.Web.QueryLog,
      Guardian.Web.IngestIdempotency,
      Guardian.Web,
      Guardian.Cluster.discovery_child_spec(),
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  @impl true
  def prep_stop(state) do
    Logger.info("Guardian: stopping")
    state
  end

  @impl true
  def stop(_state) do
    Logger.info("Guardian: stopped")
  end
end

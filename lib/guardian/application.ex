defmodule Guardian.Application do
  use Application
  require Logger

  @stopping {__MODULE__, :stopping}

  @impl true
  def start(_type, _args) do
    :persistent_term.erase(@stopping)

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

  # Runs before the tree stops. Best effort and lock-free: a query that gets past the
  # check can fail when its segments go, which is accepted. Not application env: the
  # application controller is busy stopping this application and would not answer.
  @impl true
  def prep_stop(state) do
    :persistent_term.put(@stopping, true)
    Logger.info("Guardian: stopping")
    state
  end

  @impl true
  def stop(_state) do
    Logger.info("Guardian: stopped")
  end

  @doc "Whether this machine has begun to stop, so new queries are refused."
  def stopping? do
    :persistent_term.get(@stopping, false)
  end
end

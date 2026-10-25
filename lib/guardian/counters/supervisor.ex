defmodule Guardian.Counters.Supervisor do
  @moduledoc """
  A disposable restart boundary for advisory counters. Guardian.Counters.Restarter owns
  its lifecycle and brings it back with backoff, without spending Guardian.Application's restarts.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Process presence only; does not wait for counter operations or supervisors."
  def available?(opts \\ []) do
    Enum.all?(
      [
        Keyword.get(opts, :name, __MODULE__),
        opts |> Keyword.get(:store, []) |> Keyword.get(:name, Guardian.Counters.Store),
        opts |> Keyword.get(:cluster, []) |> Keyword.get(:name, Guardian.Counters.Cluster),
      ],
      &is_pid(Process.whereis(&1))
    )
  end

  @impl true
  def init(opts) do
    children = [
      {Guardian.Counters.Store, Keyword.get(opts, :store, [])},
      {Guardian.Counters.Cluster, Keyword.get(opts, :cluster, [])},
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
  end
end

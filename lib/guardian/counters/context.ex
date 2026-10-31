defmodule Guardian.Counters.Context do
  @moduledoc "Private per-event call timeout and routing snapshot."
  @enforce_keys [:timeout_ms, :members, :store]
  defstruct [:timeout_ms, :members, :store]

  # 50 ms in releases. The test build sets a longer one at compile time (config/config.exs),
  # because a slow healthy call under host load would silently give a default count.
  @call_timeout_ms Application.compile_env(:guardian, [__MODULE__, :call_timeout_ms], 50)

  # The libtest adapter additionally interprets backend/server tuples in test builds.
  @type store :: atom() | pid() | reference()
  @type option :: {:timeout_ms, integer()} | {:members, [node()]} | {:store, store()}
  @type t :: %__MODULE__{timeout_ms: integer(), members: [node()], store: store()}

  @doc """
  Builds one event's context: the per-call timeout and a snapshot of this node plus
  connected peers as the members that own counters. The options replace those or the
  store, and exist for tests.
  """
  @spec new([option()]) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      timeout_ms: Keyword.get(opts, :timeout_ms, @call_timeout_ms),
      members: Keyword.get_lazy(opts, :members, fn -> [node() | Node.list()] end),
      store: Keyword.get(opts, :store, Guardian.Counters.Store),
    }
  end
end

defmodule Guardian.Test.Counters do
  @moduledoc """
  The store setup and event options shared by counter execution and rules tests.
  `private_store/0` starts a real store; `event_options/2` also accepts a
  `Guardian.Test.Counters.ProbeStore`. `private_store/0` starts its process with
  `start_supervised!/1`, so call it from `setup` or a test.

  Call these by their full name or import them: `alias Guardian.Test.Counters` would
  shadow `Counters` in `Guardian.Counters.*` aliases.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 1]
  alias Guardian.Test.Counters.ProbeStore

  @doc "Starts an unnamed Store under the test supervisor. Returns `%{store: store}`."
  def private_store do
    %{store: start_supervised!({Guardian.Counters.Store, name: nil})}
  end

  @doc "The Context options for an event against `store` on this node alone, merged with `opts`."
  def event_options(store, opts \\ []) do
    Keyword.merge([store: ProbeStore.backend(store), members: [node()]], opts)
  end
end

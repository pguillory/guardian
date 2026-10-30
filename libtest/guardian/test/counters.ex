defmodule Guardian.Test.Counters do
  @moduledoc """
  The store setup and event options shared by counter execution and rules tests.
  `private_store/1` starts a real store; `event_options/3` also accepts a
  `Guardian.Test.Counters.ProbeStore`.

  Tests that want larger budgets pass `Guardian.Test.Counters.Budget.relaxed_options/0`
  through `event_options/3`. `private_store/1` starts processes with
  `start_supervised!/1`, so call it from `setup` or a test.

  Call these by their full name or import them: `alias Guardian.Test.Counters` would
  shadow `Counters` in `Guardian.Counters.*` aliases.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 1]
  alias Guardian.Test.Counters.ProbeStore

  @doc """
  Starts an unnamed Store and a `Guardian.Counters.Budget` cooldown table named
  `cooldown_table` under the test supervisor. Returns `%{store: store}` for the test
  context.
  """
  def private_store(cooldown_table) do
    store = start_supervised!({Guardian.Counters.Store, name: nil})
    start_supervised!({Guardian.Counters.Budget, name: cooldown_table})
    %{store: store}
  end

  @doc """
  The Context options for an event against `store` on this node alone, using
  `cooldown_table`, merged with `opts`.
  """
  def event_options(store, cooldown_table, opts \\ []) do
    Keyword.merge(
      [store: ProbeStore.backend(store), members: [node()], cooldown_table: cooldown_table],
      opts
    )
  end
end

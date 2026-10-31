defmodule Guardian.Counters.RuntimeTest do
  # The registered names below are this module's own.
  use ExUnit.Case, async: true

  @names [
    :counter_runtime_supervisor,
    :counter_runtime_store,
  ]
  @counters [
    name: :counter_runtime_supervisor,
    store: [name: :counter_runtime_store],
  ]

  test "invalid configured store budget still refuses startup" do
    assert {:error, _} =
             start_supervised(
               {Guardian.Counters.Restarter,
                name: :counter_runtime_restarter,
                counters:
                  Keyword.put(@counters, :store,
                    name: :counter_runtime_store,
                    memory_budget_bytes: 0
                  )}
             )

    for name <- @names, do: assert(Process.whereis(name) == nil)
  end
end

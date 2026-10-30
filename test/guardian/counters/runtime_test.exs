defmodule Guardian.Counters.RuntimeTest do
  # Not async: registers the counter runtime's fixed test names.
  use ExUnit.Case, async: false

  @names [
    :counter_runtime_supervisor,
    :counter_runtime_store,
    :counter_runtime_budget,
  ]
  @counters [
    name: :counter_runtime_supervisor,
    store: [name: :counter_runtime_store],
    budget: [name: :counter_runtime_budget],
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
